import XCTest
@testable import Nuxie

final class ResponseModelContractTests: XCTestCase {
    func testEventTriggerConfigRequiresIRObjectCondition() {
        let data = Data(
            """
            {
              "eventName": "$app_opened",
              "condition": "{\"ir_version\":1,\"expr\":{\"type\":\"Bool\",\"value\":true}}"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(EventTriggerConfig.self, from: data))
    }

    func testEventResponseDecodesTopLevelEventId() throws {
        let data = Data(
            """
            {
              "status": "ok",
              "eventId": "evt_123",
              "customerId": "cus_123",
              "message": "tracked"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(EventResponse.self, from: data)

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.eventId, "evt_123")
        XCTAssertEqual(response.customerId, "cus_123")
        XCTAssertEqual(response.message, "tracked")
    }

    func testEventResponseDecodesJourneyDownFacts() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(
            """
            {
              "status": "ok",
              "facts": [{
                "id": "fact-converted-1",
                "event": "$journey_converted",
                "timestamp": "2026-07-22T18:04:11Z",
                "properties": {
                  "journey_id": "journey-1",
                  "at": "2026-07-22T18:04:10Z",
                  "source_fact_ref": "purchase-1"
                }
              }]
            }
            """.utf8
        )

        let response = try decoder.decode(EventResponse.self, from: data)

        XCTAssertEqual(response.facts?.first?.id, "fact-converted-1")
        XCTAssertEqual(response.facts?.first?.event, .converted)
        XCTAssertEqual(response.facts?.first?.properties.journeyId, "journey-1")
        XCTAssertEqual(response.facts?.first?.properties.sourceFactRef, "purchase-1")
    }

    func testProfileResponseDecodesServerSegmentSeedAndUnknownEvaluationAsServer() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(
            """
            {
              "campaigns": [],
              "segments": [{
                "id": "segment-1",
                "name": "Purchasers",
                "condition": {"ir_version": 1, "expr": {"type": "Bool", "value": true}},
                "evaluation": "future-server-mode"
              }],
              "flows": [],
              "segmentMemberships": {
                "evaluatedAt": "2026-07-22T18:04:11Z",
                "memberships": [{
                  "segmentId": "segment-1",
                  "enteredAt": "2026-05-02T09:12:00Z"
                }]
              },
              "facts": []
            }
            """.utf8
        )

        let response = try decoder.decode(ProfileResponse.self, from: data)

        XCTAssertEqual(response.segments.first?.evaluation, .server)
        XCTAssertEqual(response.segmentMemberships?.memberships.first?.segmentId, "segment-1")
        XCTAssertEqual(response.facts, [])
    }
}
