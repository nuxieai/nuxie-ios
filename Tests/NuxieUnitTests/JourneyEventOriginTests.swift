import Foundation
import XCTest
@testable import Nuxie

final class JourneyEventOriginTests: XCTestCase {
    private let origin = JourneyEventOrigin(
        journeyId: "019c0644-fc00-7000-8000-000000000001",
        experienceId: "experience", versionId: "version",
        legId: String(repeating: "a", count: 64), generation: 0,
        source: .deviceAction, stepId: "finished",
        occurrenceId: "019c0644-fc00-7000-8000-000000000002"
    )

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
