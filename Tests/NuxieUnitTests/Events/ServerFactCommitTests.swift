import Foundation
import Nimble
import Quick

@testable import Nuxie
@testable import NuxieTestSupport

final class ServerFactCommitTests: AsyncSpec {
    override class func spec() {
        describe("server fact commits") {
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

                let handled = await journeyService.handledEvents.filter { $0.id == fact.id }
                expect(handled).to(haveCount(1))
                await expect { await eventLog.getQueuedEventCount() }.to(equal(0))

                let sentNames = await api.sentEvents.map(\.name)
                expect(sentNames).to(equal(["purchase", "purchase"]))
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
