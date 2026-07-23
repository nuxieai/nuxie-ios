import FactoryKit
import XCTest

@testable import Nuxie
@testable import NuxieTestSupport

final class ServerFactCommitTests: XCTestCase {
    func testEventResponseCommitsServerFactOnceWithoutUploadingAndRoutesSubscriber() async throws {
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        let eventStore = MockEventStore()
        let identityService = MockIdentityService()
        identityService.setDistinctId("user-1")
        let api = MockNuxieApi()
        let journeyService = MockJourneyService()

        Container.shared.sdkConfiguration.register { configuration }
        Container.shared.identityService.register { identityService }
        Container.shared.nuxieApi.register { api }
        Container.shared.sessionService.register { TrackWithResponseTestSessionService() }
        Container.shared.dateProvider.register { MockDateProvider() }

        let networkQueue = NuxieNetworkQueue(
            flushAt: 100,
            flushIntervalSeconds: 30,
            apiClient: api
        )
        let eventService = EventService(eventStore: eventStore)
        try await eventService.configure(
            networkQueue: networkQueue,
            journeyService: journeyService
        )
        defer {
            Task {
                await networkQueue.shutdown()
                await eventService.close()
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

        _ = try await eventService.trackWithResponse("purchase", properties: nil)
        _ = try await eventService.trackWithResponse("purchase", properties: nil)
        await eventService.drain()

        let committed = eventStore.storedEvents.filter { $0.id == fact.id }
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.name, "$journey_converted")
        XCTAssertEqual(committed.first?.origin, .server)
        XCTAssertEqual(committed.first?.getPropertiesDict()["source_fact_ref"] as? String, "purchase-1")

        let handled = await journeyService.handledEvents.filter { $0.id == fact.id }
        XCTAssertEqual(handled.count, 1)
        let queuedCount = await networkQueue.getQueueSize()
        XCTAssertEqual(queuedCount, 0)

        let sentNames = await api.sentEvents.map(\.name)
        XCTAssertEqual(sentNames, ["purchase", "purchase"])
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
