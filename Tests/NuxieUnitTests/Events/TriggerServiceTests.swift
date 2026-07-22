import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor FlowShownBeforeJourneyDecisionService: JourneyServiceProtocol {
    private let broker: TriggerBrokerProtocol
    private let journey: Journey
    private let finalUpdate: JourneyUpdate

    init(broker: TriggerBrokerProtocol, journey: Journey, finalUpdate: JourneyUpdate) {
        self.broker = broker
        self.journey = journey
        self.finalUpdate = finalUpdate
    }

    func startJourney(for campaign: Campaign, distinctId: String, originEventId: String?) async -> Journey? {
        nil
    }

    func resumeJourney(_ journey: Journey) async {}


    func handleEvent(_ event: NuxieEvent) async {}

    func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] {
        let ref = JourneyRef(
            journeyId: journey.id,
            campaignId: journey.campaignId,
            flowId: journey.flowId
        )
        await broker.emit(eventId: event.id, update: .decision(.flowShown(ref)))

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
        var featureInfo: FeatureInfo!
        var featureService: FeatureService!
        var triggerBroker: TriggerBroker!
        var triggerService: TriggerServiceProtocol!

        beforeEach {
            let testConfig = NuxieConfiguration(apiKey: "test-api-key")

            mockEventLog = MockEventLog()
            mockJourneyService = MockJourneyService()
            mockFlowPresentationService = MockExperiencePresentationService()
            mockSleepProvider = MockSleepProvider()
            mockSleepProvider.shouldCompleteImmediately = true
            mockDateProvider = MockDateProvider()
            featureInfo = FeatureInfo()
            featureService = FeatureService(
                api: MockNuxieApi(),
                identity: MockIdentityService(),
                profile: MockProfileService(),
                dateProvider: mockDateProvider,
                featureInfo: featureInfo,
                configProvider: { testConfig }
            )
            triggerBroker = TriggerBroker()

            triggerService = TriggerService(
                eventLog: mockEventLog,
                journeys: mockJourneyService,
                features: featureService,
                flowPresentation: mockFlowPresentationService,
                featureInfo: featureInfo,
                triggerBroker: triggerBroker,
                sleepProvider: mockSleepProvider,
                dateProvider: mockDateProvider
            )
        }

        describe("trigger") {
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
                    execution: nil
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

            it("emits journeyStarted when a journey starts") {
                let journey = TestJourneyBuilder().build()
                await mockJourneyService.setTriggerResults([.started(journey)])
                mockEventLog.trackWithResponseResult = .success()

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
            }

            it("keeps the broker alive when a journey flowShown arrives before journeyStarted") {
                let journey = TestJourneyBuilder().build()
                let expectedRef = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                let finalUpdate = JourneyUpdate(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId,
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
                    flowPresentation: mockFlowPresentationService,
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
                expect(updates.values).to(contain(.decision(.flowShown(expectedRef))))
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
                    execution: nil
                )

                let finalUpdate = JourneyUpdate(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId,
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
                    execution: nil
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.decision(.suppressed(.alreadyActive))))
                expect(mockFlowPresentationService.presentFlowCallCount).to(equal(1))
                expect(mockFlowPresentationService.lastPresentedFlowId).to(equal("server-flow"))
                let showedServerFlow = updates.values.contains { update in
                    guard case .decision(.flowShown(let ref)) = update else { return false }
                    return ref.campaignId == "flow:server-flow" && ref.flowId == "server-flow"
                }
                expect(showedServerFlow).to(beTrue())
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
                    execution: nil
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let expectedRef = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
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
                    execution: nil
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
                    execution: nil
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

                let expectedRef = JourneyRef(
                    journeyId: journey.id,
                    campaignId: journey.campaignId,
                    flowId: journey.flowId
                )
                expect(updates.values).to(contain(.decision(.journeyStarted(expectedRef))))
                expect(updates.values).to(contain(.entitlement(.allowed(source: .cache))))
            }

            it("emits entitlement allowed for cache_only gate plan with cached access") {
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
                    execution: nil
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

                expect(updates.values).to(contain(.entitlement(.allowed(source: .cache))))
            }

            it("emits entitlement denied for cache_only gate plan without access") {
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
                    execution: nil
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                expect(updates.values).to(contain(.entitlement(.denied)))
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
}
