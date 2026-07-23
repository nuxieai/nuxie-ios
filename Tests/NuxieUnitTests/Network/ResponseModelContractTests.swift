import Foundation
import Nimble
import Quick

@testable import Nuxie

final class ResponseModelContractTests: QuickSpec {
    override class func spec() {
        describe("response wire contracts") {
            it("uses journey_id for response capture") {
                let request = ResponseFieldRequest(
                    distinctId: "customer-1",
                    journeyId: "journey-1",
                    responseSchemaId: "schema-1",
                    schemaVersion: 1,
                    key: "answer",
                    value: AnyCodable("yes")
                )

                let object = try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(request)
                ) as? [String: Any]

                expect(object?["journey_id"] as? String).to(equal("journey-1"))
                expect(object?["journey_session_id"]).to(beNil())
            }

            it("decodes a response record journey id") {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let data = Data(
                    """
                    {
                      "id": "response-1",
                      "campaignId": "campaign-1",
                      "journeyId": "journey-1",
                      "customerId": "customer-1",
                      "responseSchemaId": "schema-1",
                      "responseSchemaVersionId": "schema-version-1",
                      "schemaVersion": 1,
                      "state": "draft",
                      "values": {},
                      "createdAt": "2026-07-22T18:04:11Z",
                      "updatedAt": "2026-07-22T18:04:11Z",
                      "submittedAt": null,
                      "abandonedAt": null
                    }
                    """.utf8
                )

                let response = try decoder.decode(ResponseRecordPayload.self, from: data)

                expect(response.journeyId).to(equal("journey-1"))
            }

            it("requires an IR object for event trigger conditions") {
                let data = Data(
                    """
                    {
                      "eventName": "$app_opened",
                      "condition": "{\"ir_version\":1,\"expr\":{\"type\":\"Bool\",\"value\":true}}"
                    }
                    """.utf8
                )

                expect {
                    try JSONDecoder().decode(EventTriggerConfig.self, from: data)
                }.to(throwError())
            }

            it("decodes the top-level event id") {
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

                expect(response.status).to(equal("ok"))
                expect(response.eventId).to(equal("evt_123"))
                expect(response.customerId).to(equal("cus_123"))
                expect(response.message).to(equal("tracked"))
            }

            it("decodes journey down facts") {
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

                expect(response.facts?.first?.id).to(equal("fact-converted-1"))
                expect(response.facts?.first?.event).to(equal(.converted))
                expect(response.facts?.first?.properties.journeyId).to(equal("journey-1"))
                expect(response.facts?.first?.properties.sourceFactRef).to(equal("purchase-1"))
            }

            it("decodes server segment seeds and treats unknown evaluation as server") {
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

                expect(response.segments.first?.evaluation).to(equal(.server))
                expect(response.segmentMemberships?.memberships.first?.segmentId)
                    .to(equal("segment-1"))
                expect(response.facts).to(equal([]))
            }
        }
    }
}
