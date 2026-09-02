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

private actor CommittedSystemEventRecorder {
    private var eventIds: [String] = []

    func append(_ event: NuxieEvent) {
        eventIds.append(event.id)
    }

    func values() -> [String] {
        eventIds
    }
}

final class TriggerServiceTests: AsyncSpec {
    override class func spec() {
        var mockEventLog: MockEventLog!
        var mockJourneyService: MockJourneyService!
        var mockDateProvider: MockDateProvider!
        var triggerBroker: TriggerBroker!
        var triggerService: TriggerServiceProtocol!

        beforeEach {
            mockEventLog = MockEventLog()
            mockJourneyService = MockJourneyService()
            mockDateProvider = MockDateProvider()
            triggerBroker = TriggerBroker()

            triggerService = TriggerService(
                eventLog: mockEventLog,
                journeys: mockJourneyService,
                triggerBroker: triggerBroker,
                dateProvider: mockDateProvider
            )
        }

        describe("trigger") {
            it("routes durable-carrier system events in the committing capture") {
                let eventLog = MockEventLog()
                let recorder = CommittedSystemEventRecorder()
                await eventLog.subscribeCommitted { event in
                    await recorder.append(event)
                }
                let fallbackTrigger = MockTriggerService()
                let sink = TriggerSystemEventSink(
                    routedEvents: eventLog,
                    triggerProvider: { fallbackTrigger }
                )

                let captured = await sink.captureStableSystemEvent(
                    SystemEventNames.purchaseCompleted,
                    properties: ["transaction_id": "transaction-committed"],
                    eventId: "purchase-completed:committed-subscriber",
                    distinctId: "customer-a",
                    routeToJourneys: true,
                    ensureDurableCarrier: true
                )

                expect(captured).to(beTrue())
                let recordedEventIds = await recorder.values()
                expect(recordedEventIds).to(equal([
                    "purchase-completed:committed-subscriber",
                ]))
                expect(eventLog.committedRoutingDrainCallCount).to(equal(1))
            }

            it("retains failed live stable captures for ordered retry") {
                let eventLog = MockEventLog()
                eventLog.routedCaptureFailuresRemaining = 1
                let recorder = CommittedSystemEventRecorder()
                await eventLog.subscribeCommitted { event in
                    await recorder.append(event)
                }
                let sink = TriggerSystemEventSink(
                    routedEvents: eventLog,
                    stableCaptureRetryBaseDelayNanoseconds: 1_000_000,
                    triggerProvider: { MockTriggerService() }
                )
                let eventId = "purchase-failed:queued-capture"

                let accepted = await sink.capture(
                    SystemEventNames.purchaseFailed,
                    properties: ["reason": "store_unavailable"],
                    eventId: eventId,
                    distinctId: "customer-a"
                )
                let duplicateWhilePending = await sink.capture(
                    SystemEventNames.purchaseFailed,
                    properties: ["reason": "store_unavailable"],
                    eventId: eventId,
                    distinctId: "customer-a"
                )

                expect(accepted).to(beFalse())
                expect(duplicateWhilePending).to(beFalse())
                await expect { await recorder.values() }.toEventually(
                    equal([eventId]),
                    timeout: .seconds(1)
                )
            }

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

            it("ignores legacy gate payloads without routing side effects") {
                let payload: [String: AnyCodable] = [
                    "gate": AnyCodable([
                        "decision": "require_feature",
                        "featureId": "pro",
                        "flowId": "legacy-fallback",
                        "policy": "hard",
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

                let handledEvents = await mockJourneyService.handledEvents
                expect(updates.values).to(equal([.decision(.noMatch)]))
                expect(handledEvents).to(haveCount(1))
            }

            it("ignores unwrapped legacy show_flow payloads without routing side effects") {
                let payload: [String: AnyCodable] = [
                    "decision": AnyCodable("show_flow"),
                    "flowId": AnyCodable("legacy-fallback"),
                    "policy": AnyCodable("hard"),
                ]
                mockEventLog.trackWithResponseResult = EventResponse(
                    status: "ok",
                    payload: payload,
                    customer: nil,
                    eventId: "event-unwrapped-legacy-gate",
                    message: nil,
                    featuresMatched: nil,
                    usage: nil,
                    journey: nil,
                )

                let updates = TriggerUpdateRecorder()

                await triggerService.trigger("test_event") { update in
                    updates.append(update)
                }

                let handledEvents = await mockJourneyService.handledEvents
                expect(updates.values).to(equal([.decision(.noMatch)]))
                expect(handledEvents).to(haveCount(1))
            }

            it("emits noMatch when no journeys start") {
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
                    payload: nil,
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
                    triggerBroker: broker,
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
