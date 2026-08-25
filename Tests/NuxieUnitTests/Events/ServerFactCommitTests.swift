import Foundation
import Nimble
import Quick

@testable import Nuxie
@testable import NuxieTestSupport

final class ServerFactCommitTests: AsyncSpec {
    override class func spec() {
        describe("server fact commits") {
            it("durably queues an effect request before an offline pause is persisted") {
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                let eventStore = MockEventStore()
                let identityService = MockIdentityService()
                identityService.setDistinctId("user-1")
                let eventLog = EventLog(
                    identity: identityService,
                    sessions: TrackWithResponseTestSessionService(),
                    dateProvider: MockDateProvider(),
                    apiClient: MockNuxieApi(),
                    store: eventStore
                )
                try await eventLog.configure(configuration: configuration)
                defer { Task { await eventLog.close() } }

                eventLog.track(
                    JourneyEvents.journeyEffectRequested,
                    properties: [
                        "journey_id": "journey-1",
                        "node_id": "send-email",
                        "invocation_id": "invocation-1",
                        "effect": [
                            "kind": "connector_tool",
                            "account_ref": "account-1",
                            "tool_key": "resend.RESEND_SEND_EMAIL",
                        ],
                        "payload": ["to": "person@example.com"],
                    ],
                    userProperties: nil,
                    userPropertiesSetOnce: nil
                )
                await eventLog.drain()

                expect(
                    eventStore.storedEvents.first {
                        $0.name == JourneyEvents.journeyEffectRequested
                    }
                ).toNot(beNil())
                await expect { await eventLog.getQueuedEventCount() }.to(equal(1))
            }

            it("commits once without uploading and routes the subscriber") {
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                let eventStore = MockEventStore()
                let identityService = MockIdentityService()
                identityService.setDistinctId("user-1")
                let api = MockNuxieApi()
                let journeyService = MockJourneyService()

                let eventLog = EventLog(
                    identity: identityService,
                    sessions: TrackWithResponseTestSessionService(),
                    dateProvider: MockDateProvider(),
                    apiClient: api,
                    store: eventStore
                )
                await eventLog.subscribeCommitted { [weak journeyService] event in
                    await journeyService?.handleEvent(event)
                }
                try await eventLog.configure(configuration: configuration)
                defer {
                    Task {
                        await eventLog.close()
                    }
                }

                let fact = JourneyDownFact(
                    id: "fact-converted-1",
                    event: .converted,
                    timestamp: Date(timeIntervalSince1970: 1_753_207_451),
                    properties: JourneyConvertedProperties(
                        journeyId: "journey-1",
                        experienceId: "experience-1",
                        experienceVersion: "flow-version-1",
                        at: Date(timeIntervalSince1970: 1_753_207_450),
                        sourceFactRef: "purchase-1"
                    )
                )
                await api.setTrackEventResponse(EventResponse(status: "ok", facts: [fact]))

                _ = try await eventLog.trackWithResponse("purchase", properties: nil)
                _ = try await eventLog.trackWithResponse("purchase", properties: nil)
                await eventLog.drain()

                let committed = eventStore.storedEvents.filter { $0.id == fact.id }
                expect(committed).to(haveCount(1))
                expect(committed.first?.name).to(equal("$journey_converted"))
                expect(committed.first?.origin).to(equal(.server))
                expect(committed.first?.getPropertiesDict()["source_fact_ref"] as? String)
                    .to(equal("purchase-1"))
                expect(committed.first?.getPropertiesDict()["experience_id"] as? String)
                    .to(equal("experience-1"))
                expect(committed.first?.getPropertiesDict()["experience_version"] as? String)
                    .to(equal("flow-version-1"))

                let handled = await journeyService.handledEvents.filter { $0.id == fact.id }
                expect(handled).to(haveCount(1))
                expect(handled.first?.properties["experience_id"] as? String)
                    .to(equal("experience-1"))
                expect(handled.first?.properties["experience_version"] as? String)
                    .to(equal("flow-version-1"))
                await expect { await eventLog.getQueuedEventCount() }.to(equal(0))

                let sentNames = await api.sentEvents.map(\.name)
                expect(sentNames).to(equal(["purchase", "purchase"]))
            }

            it("commits effect completions through the same subscriber lane") {
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                let eventStore = MockEventStore()
                let identityService = MockIdentityService()
                identityService.setDistinctId("user-1")
                let eventLog = EventLog(
                    identity: identityService,
                    sessions: TrackWithResponseTestSessionService(),
                    dateProvider: MockDateProvider(),
                    apiClient: MockNuxieApi(),
                    store: eventStore
                )
                let journeyService = MockJourneyService()
                await eventLog.subscribeCommitted { [weak journeyService] event in
                    await journeyService?.handleEvent(event)
                }
                try await eventLog.configure(configuration: configuration)
                defer { Task { await eventLog.close() } }

                let json = """
                {
                  "id": "fact-effect-1",
                  "event": "$journey_effect_completed",
                  "timestamp": "2025-07-22T12:00:00Z",
                  "properties": {
                    "journey_id": "journey-1",
                    "node_id": "send-email",
                    "invocation_id": "invocation-1",
                    "status": "ok",
                    "result": {"message_id": "message-1"}
                  }
                }
                """
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let fact = try decoder.decode(JourneyDownFact.self, from: Data(json.utf8))

                await eventLog.commitServerFacts([fact], distinctId: "user-1")
                await eventLog.drain()

                let committed = eventStore.storedEvents.first { $0.id == fact.id }
                expect(committed?.name).to(equal(JourneyEvents.journeyEffectCompleted))
                expect(committed?.getPropertiesDict()["node_id"] as? String)
                    .to(equal("send-email"))
                expect(committed?.getPropertiesDict()["status"] as? String).to(equal("ok"))
                let handled = await journeyService.handledEvents.filter {
                    $0.id == fact.id
                }
                expect(handled).to(haveCount(1))
            }
        }
    }
}

private final class TrackWithResponseTestSessionService: SessionServiceProtocol {
    func getSessionId(at date: Date, readOnly: Bool) -> String? { "session-1" }
    func getNextSessionId() -> String? { "session-2" }
    func setSessionId(_ sessionId: String) {}
    func startSession() {}
    func touchSession() {}
    func resetSession() {}
    func reset() {}
    func endSession() {}
    func onAppDidEnterBackground() {}
    func onAppBecameActive() {}
}
