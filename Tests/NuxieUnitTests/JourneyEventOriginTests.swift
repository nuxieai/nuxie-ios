import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyEventOriginTests: XCTestCase {
    private let origin = JourneyEventOrigin(
        journeyId: "019c0644-fc00-7000-8000-000000000001",
        experienceId: "experience", versionId: "version",
        legId: String(repeating: "a", count: 64), generation: 0,
        source: .deviceAction, stepId: "finished",
        occurrenceId: "019c0644-fc00-7000-8000-000000000002"
    )

    func testStableCaptureKeepsOriginThroughRedactionReopenAndBatchDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = NuxieConfiguration(apiKey: "test-origin")
        configuration.testingOverrides.customStoragePath = directory
        configuration.testingOverrides.flushAt = 100
        configuration.beforeSend = { event in
            NuxieEvent(id: event.id, name: event.name, distinctId: event.distinctId,
                properties: ["redacted": true], timestamp: event.timestamp)
        }
        let api = MockNuxieApiForQueue()
        let first = EventLog(identity: MockIdentityService(), dateProvider: MockDateProvider(),
            apiClient: api, store: SQLiteEventStore())
        try await first.configure(configuration: configuration)
        let captured = await first.captureAndRouteSystemEvent(.init(
            name: "finished", properties: ["secret": "removed"], eventId: origin.occurrenceId,
            distinctId: "customer", journeyOrigin: origin
        ))
        XCTAssertEqual(captured?.event.journeyOrigin, origin)
        XCTAssertNil(captured?.event.properties["secret"])
        await first.close()

        let reopened = EventLog(identity: MockIdentityService(), dateProvider: MockDateProvider(),
            apiClient: api, store: SQLiteEventStore())
        try await reopened.configure(configuration: configuration)
        let duplicate = await reopened.captureAndRouteSystemEvent(.init(
            name: "finished", properties: [:], eventId: origin.occurrenceId,
            distinctId: "customer", journeyOrigin: origin
        ))
        XCTAssertEqual(duplicate?.event.journeyOrigin, origin)
        XCTAssertEqual(duplicate?.isNewlyCommitted, false)
        let flushed = await reopened.flushEvents()
        XCTAssertTrue(flushed)
        let batches = await api.allBatchesSent
        let delivered = try XCTUnwrap(batches.flatMap { $0 }.first { $0.idempotencyKey == origin.occurrenceId })
        XCTAssertEqual(delivered.journeyOrigin, origin)
        XCTAssertNil(delivered.properties?["secret"])
        await reopened.close()
    }

    func testInternalOriginSurvivesBothWireLanesOutsideAnalytics() throws {
        let event = NuxieEvent(
            id: origin.occurrenceId, name: "finished", forwardingName: "finished",
            distinctId: "customer", properties: ["answer": 42], timestamp: Date(),
            journeyOrigin: origin
        )
        let payloads = [
            try JSONEncoder().encode(EventRequest(event: event)),
            try JSONEncoder().encode(BatchEventItem(event: event)),
        ]
        for data in payloads {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let context = try XCTUnwrap(object["journeyOrigin"] as? [String: Any])
            XCTAssertEqual(context["source"] as? String, "device_action")
            XCTAssertEqual(context["stepId"] as? String, "finished")
            XCTAssertEqual(context["occurrenceId"] as? String, origin.occurrenceId)
            XCTAssertEqual(object["idempotency_key"] as? String, origin.occurrenceId)
            let properties = try XCTUnwrap(object["properties"] as? [String: Any])
            XCTAssertEqual(properties.count, 1)
            XCTAssertEqual(properties["answer"] as? Int, 42)
        }
    }

    func testPublicEventPropertiesCannotManufactureInternalOrigin() throws {
        let event = NuxieEvent(name: "finished", distinctId: "customer", properties: [
            "journeyOrigin": ["source": "device_action"],
            "journey_id": origin.journeyId,
        ])
        XCTAssertNil(event.journeyOrigin)
        let data = try JSONEncoder().encode(BatchEventItem(event: event))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["journeyOrigin"])
    }

    func testStoredEventSerializationRetainsOriginSeparately() throws {
        let event = try StoredEvent(
            id: origin.occurrenceId, name: "finished", properties: ["answer": 42],
            distinctId: "customer", journeyOrigin: origin
        )
        let decoded = try JSONDecoder().decode(StoredEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.journeyOrigin, origin)
        XCTAssertEqual(decoded.getPropertiesDict().count, 1)
        XCTAssertEqual(decoded.getPropertiesDict()["answer"] as? Int, 42)
    }
}
