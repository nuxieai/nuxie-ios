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
                      "experienceId": "experience-1",
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

            it("decodes flat package pointers, pinned versions, and the asset base URL") {
                let data = Data(
                    """
                    {
                      "experiences": [{
                        "experienceId": "experience-1",
                        "versionId": "version-2",
                        "buildId": "build-2",
                        "artifact": {
                          "url": "https://cdn.example/version-2/experience.nux",
                          "sha256": "2222222222222222222222222222222222222222222222222222222222222222",
                          "sizeBytes": 128,
                          "packageVersion": 1
                        },
                        "name": "Onboarding",
                        "reentry": {"type": "one_time"},
                        "publishedAt": "2026-07-25T18:04:11Z",
                        "timeLimitSeconds": 3600
                      }],
                      "pinnedVersions": [{
                        "experienceId": "experience-1",
                        "versionId": "version-1",
                        "buildId": "build-1",
                        "artifact": {
                          "url": "https://cdn.example/version-1/experience.nux",
                          "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
                          "sizeBytes": 96,
                          "packageVersion": 1
                        },
                        "name": "Onboarding",
                        "reentry": {"type": "one_time"},
                        "publishedAt": "2026-07-24T18:04:11Z"
                      }],
                      "assetBaseUrl": "https://assets.example/sha256/",
                      "segments": []
                    }
                    """.utf8
                )

                let response = try JSONDecoder().decode(ProfileResponse.self, from: data)

                expect(response.experiences.first?.experienceId).to(equal("experience-1"))
                expect(response.experiences.first?.trigger).to(beNil())
                expect(response.experiences.first?.timeLimitSeconds).to(equal(3600))
                expect(response.experiences.first?.versionId).to(equal("version-2"))
                expect(response.pinnedVersions.first?.versionId).to(equal("version-1"))
                expect(response.assetBaseUrl).to(equal("https://assets.example/sha256/"))
            }

            it("rejects the deleted campaigns and flows profile shape") {
                let data = Data(
                    """
                    {
                      "campaigns": [],
                      "flows": [],
                      "segments": []
                    }
                    """.utf8
                )

                expect {
                    try JSONDecoder().decode(ProfileResponse.self, from: data)
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
                guard case .converted(let properties) = response.facts?.first?.properties else {
                    fail("Expected converted journey fact")
                    return
                }
                expect(properties.journeyId).to(equal("journey-1"))
                expect(properties.sourceFactRef).to(equal("purchase-1"))
            }

            it("decodes mailbox offers, hints, claim acknowledgements, and supersede facts") {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let profileData = Data(
                    """
                    {
                      "experiences": [],
                      "segments": [],
                      "pinnedVersions": [],
                      "assetBaseUrl": "https://assets.example/sha256/",
                      "mailbox": [{
                        "kind": "claimable",
                        "journeyId": "journey-1",
                        "experienceId": "experience-1",
                        "experienceVersion": "flow-1",
                        "epoch": 3,
                        "stateVersion": 1,
                        "envelope": {
                          "stateVersion": 1,
                          "context": {"source": "server"},
                          "flowState": {
                            "plane": "device",
                            "regionId": "device-2",
                            "currentNodeId": "screen-a"
                          },
                          "snapshots": {}
                        },
                        "expiresAt": "2026-07-26T18:04:11Z",
                        "resumeNodeId": "screen-a",
                        "checkpointAt": "2026-07-26T17:54:11Z"
                      }]
                    }
                    """.utf8
                )
                let eventData = Data(
                    """
                    {
                      "status": "ok",
                      "mailboxPending": true,
                      "journeyClaim": {
                        "journeyId": "journey-1",
                        "accepted": true,
                        "epoch": 4
                      },
                      "journeyOwnership": {
                        "journeyId": "journey-2",
                        "accepted": false,
                        "epoch": 8,
                        "reason": "stale_epoch"
                      },
                      "facts": [{
                        "id": "fact-superseded-1",
                        "event": "$journey_superseded",
                        "timestamp": "2026-07-25T18:04:11Z",
                        "properties": {
                          "journey_id": "journey-1",
                          "winner_journey_id": "journey-2"
                        }
                      }]
                    }
                    """.utf8
                )

                let profile = try decoder.decode(ProfileResponse.self, from: profileData)
                let event = try decoder.decode(EventResponse.self, from: eventData)

                expect(profile.mailbox?.first?.journeyId).to(equal("journey-1"))
                expect(profile.mailbox?.first?.epoch).to(equal(3))
                expect(profile.mailbox?.first?.kind).to(equal(.claimable))
                expect(profile.mailbox?.first?.resumeNodeId).to(equal("screen-a"))
                expect(profile.mailbox?.first?.checkpointAt)
                    .to(equal(
                        ISO8601DateFormatter().date(
                            from: "2026-07-26T17:54:11Z"
                        )
                    ))
                expect(profile.mailbox?.first?.envelope.executionState.plane)
                    .to(equal(.device))
                expect(profile.mailbox?.first?.envelope.context["source"]?.value as? String)
                    .to(equal("server"))
                expect(event.mailboxPending).to(beTrue())
                expect(event.journeyClaim?.journeyId).to(equal("journey-1"))
                expect(event.journeyClaim?.accepted).to(beTrue())
                expect(event.journeyClaim?.epoch).to(equal(4))
                expect(event.journeyOwnership?.journeyId).to(equal("journey-2"))
                expect(event.journeyOwnership?.accepted).to(beFalse())
                expect(event.journeyOwnership?.epoch).to(equal(8))
                expect(event.journeyOwnership?.reason).to(equal("stale_epoch"))
                expect(event.facts?.first?.event).to(equal(.superseded))
                guard case .superseded(let superseded) = event.facts?.first?.properties else {
                    fail("Expected superseded journey fact")
                    return
                }
                expect(superseded.journeyId).to(equal("journey-1"))
                expect(superseded.winnerJourneyId).to(equal("journey-2"))
            }

            it("decodes server segment seeds and treats unknown evaluation as server") {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let data = Data(
                    """
                    {
                      "experiences": [],
                      "assetBaseUrl": "https://assets.example/sha256/",
                      "segments": [{
                        "id": "segment-1",
                        "name": "Purchasers",
                        "condition": {"ir_version": 1, "expr": {"type": "Bool", "value": true}},
                        "evaluation": "future-server-mode"
                      }],
                      "pinnedVersions": [],
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
