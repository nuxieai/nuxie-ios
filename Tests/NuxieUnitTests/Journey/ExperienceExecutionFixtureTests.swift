import Foundation
import CryptoKit
import Nimble
import Quick

@testable import Nuxie

final class ExperienceExecutionFixtureTests: AsyncSpec {
    override class func spec() {
        describe("Experiences shared fixtures") {
            it("produces exact ordered transition facts") {
                let fixture = try Self.loadObject("journeys/transitions/basic.json")
                let timeline: [[String: Any]] = try Self.required(
                    fixture["timeline"] as? [[String: Any]],
                    "timeline"
                )
                let expected: [[String: Any]] = try Self.required(
                    fixture["expected"] as? [[String: Any]],
                    "expected"
                )
                let journeyId: String = try Self.required(
                    fixture["journeyId"] as? String,
                    "journeyId"
                )
                let journey = Journey(
                    id: journeyId,
                    experience: Self.makeExperience(),
                    distinctId: "user-1",
                    now: Date(timeIntervalSince1970: 1_700_000_000)
                )

                let actual = timeline.map { step -> [String: Any] in
                    let fromNode = step["fromNode"] as? String
                    let toNode = step["toNode"] as! String
                    return [
                        "event": JourneyEvents.journeyTransition,
                        "properties": JourneyEvents.journeyTransitionProperties(
                            journey: journey,
                            fromNode: fromNode,
                            toNode: toNode
                        ),
                    ]
                }

                expect(actual as NSArray).to(equal(expected as NSArray))
            }

            it("mirrors the server seed timeline") {
                let fixture = try Self.loadObject("segments/seed-mirror/server-mode.json")
                let distinctId: String = try Self.required(
                    fixture["distinctId"] as? String,
                    "distinctId"
                )
                let definitions: [[String: Any]] = try Self.required(
                    fixture["definitions"] as? [[String: Any]],
                    "definitions"
                )
                let timeline: [[String: Any]] = try Self.required(
                    fixture["timeline"] as? [[String: Any]],
                    "timeline"
                )
                let service = SegmentService()
                let segments = definitions.map { definition in
                    Segment(
                        id: definition["id"] as! String,
                        name: definition["name"] as! String,
                        condition: IREnvelope(
                            ir_version: 1,
                            engine_min: nil,
                            compiled_at: nil,
                            expr: .bool(true)
                        ),
                        evaluation: .server
                    )
                }
                await service.updateSegments(segments, for: distinctId)

                for step in timeline {
                    let generation = (step["generation"] as! NSNumber).uint64Value
                    let seed: SegmentMembershipSeed?
                    if let seedObject = step["seed"] as? [String: Any] {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        seed = try decoder.decode(
                            SegmentMembershipSeed.self,
                            from: JSONSerialization.data(withJSONObject: seedObject)
                        )
                    } else {
                        seed = nil
                    }
                    let result = await service.applySeed(
                        seed,
                        generation: generation,
                        distinctId: distinctId
                    )
                    let memberships = await service.getCurrentMemberships()
                    expect(memberships.map(\.segmentId))
                        .to(equal(step["expectedMembershipIds"] as? [String]))
                    expect(result?.entered.map(\.id) ?? [])
                        .to(equal(step["expectedEnteredIds"] as? [String]))
                    expect(result?.exited.map(\.id) ?? [])
                        .to(equal(step["expectedExitedIds"] as? [String]))
                }

                await service.clearSegments(for: distinctId)
            }

            it("decodes down-fact and golden-vocabulary fixtures") {
                let downFactFixture = try Self.loadObject("events/down-facts/converted.json")
                let responseObject: [String: Any] = try Self.required(
                    downFactFixture["response"] as? [String: Any],
                    "response"
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let response = try decoder.decode(
                    EventResponse.self,
                    from: JSONSerialization.data(withJSONObject: responseObject)
                )
                expect(response.facts?.map(\.id))
                    .to(equal(["fact-converted-1", "fact-converted-1"]))
                expect(response.facts?.map(\.event)).to(equal([.converted, .converted]))

                let golden = try Self.loadObject("golden-journey/basic.json")
                expect(golden["events"] as? [String]).to(equal([
                    JourneyEvents.journeyEnrolled,
                    JourneyEvents.journeyTransition,
                    JourneyEvents.journeyMilestone,
                    JourneyEvents.journeyConverted,
                    JourneyEvents.journeyExited,
                ]))
            }

            it("pins experience event names and property vocabulary") {
                let fixture = try Self.loadObject("events/experience-events.json")
                let expected: [[String: Any]] = try Self.required(
                    fixture["events"] as? [[String: Any]],
                    "events"
                )
                let journey = Journey(
                    id: "journey-event-vector",
                    experience: Self.makeExperience(),
                    distinctId: "event-vector-user",
                    now: Date(timeIntervalSince1970: 1_700_000_000)
                )
                func vector(_ event: String, _ properties: [String: Any]) -> [String: Any] {
                    [
                        "event": event,
                        "properties": properties.keys.sorted(),
                    ]
                }

                let actual = [
                    vector(
                        JourneyEvents.experienceShown,
                        JourneyEvents.experienceShownProperties(
                            experienceVersion: "flow-version-1",
                            journey: journey
                        )
                    ),
                    vector(
                        JourneyEvents.experienceDismissed,
                        JourneyEvents.experienceDismissedProperties(
                            experienceVersion: "flow-version-1",
                            journey: journey
                        )
                    ),
                    vector(
                        JourneyEvents.experiencePurchased,
                        JourneyEvents.experiencePurchasedProperties(
                            experienceVersion: "flow-version-1",
                            journey: journey,
                            productId: "product-1"
                        )
                    ),
                    vector(
                        JourneyEvents.experienceTimedOut,
                        JourneyEvents.experienceTimedOutProperties(
                            experienceVersion: "flow-version-1",
                            journey: journey
                        )
                    ),
                    vector(
                        JourneyEvents.experienceErrored,
                        JourneyEvents.experienceErroredProperties(
                            experienceVersion: "flow-version-1",
                            journey: journey,
                            errorMessage: "failed"
                        )
                    ),
                    vector(
                        JourneyEvents.experienceArtifactLoadSucceeded,
                        JourneyEvents.experienceArtifactLoadSucceededProperties(
                            experienceVersion: "flow-version-1",
                            artifactBuildId: "build-1",
                            artifactSource: "network",
                            artifactContentHash: "hash-1"
                        )
                    ),
                    vector(
                        JourneyEvents.experienceArtifactLoadFailed,
                        JourneyEvents.experienceArtifactLoadFailedProperties(
                            experienceVersion: "flow-version-1",
                            artifactBuildId: "build-1",
                            artifactSource: "network",
                            artifactContentHash: "hash-1",
                            errorMessage: "failed"
                        )
                    ),
                    vector(
                        JourneyEvents.customerUpdated,
                        JourneyEvents.customerUpdatedProperties(
                            journey: journey,
                            screenId: "screen-1",
                            attributesUpdated: ["email"]
                        )
                    ),
                    vector(
                        JourneyEvents.eventSent,
                        JourneyEvents.eventSentProperties(
                            journey: journey,
                            screenId: "screen-1",
                            eventName: "submitted",
                            eventProperties: ["source": "vector"]
                        )
                    ),
                    vector(
                        JourneyEvents.delegateCalled,
                        JourneyEvents.delegateCalledProperties(
                            journey: journey,
                            screenId: "screen-1",
                            message: "complete",
                            payload: ["source": "vector"]
                        )
                    ),
                    vector(
                        JourneyEvents.experimentExposure,
                        JourneyEvents.experimentExposureProperties(
                            journey: journey,
                            experimentKey: "experiment-1",
                            variantKey: "variant-1",
                            experienceVersion: "flow-version-1",
                            isHoldout: false
                        )
                    ),
                ]

                expect(actual as NSArray).to(equal(expected as NSArray))
            }

            it("pins the server effect invocation and completion union") {
                let fixture = try Self.loadObject("journeys/effects/round-trip.json")
                let journeyId: String = try Self.required(
                    fixture["journeyId"] as? String,
                    "journeyId"
                )
                let nodeId: String = try Self.required(
                    fixture["nodeId"] as? String,
                    "nodeId"
                )
                let attempt: Int = try Self.required(
                    fixture["attempt"] as? Int,
                    "attempt"
                )
                let invocationId: String = try Self.required(
                    fixture["invocationId"] as? String,
                    "invocationId"
                )
                expect(JourneyRunner.effectInvocationId(
                    journeyId: journeyId,
                    nodeId: nodeId,
                    attempt: attempt
                )).to(equal(invocationId))

                let completion: [String: Any] = try Self.required(
                    fixture["completion"] as? [String: Any],
                    "completion"
                )
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let fact = try decoder.decode(
                    JourneyDownFact.self,
                    from: JSONSerialization.data(withJSONObject: completion)
                )
                expect(fact.event).to(equal(.effectCompleted))
                guard case .effectCompleted(let properties) = fact.properties else {
                    fail("Expected effect completion properties")
                    return
                }
                expect(properties.nodeId).to(equal(nodeId))
                expect(properties.invocationId).to(equal(invocationId))
                expect(properties.status).to(equal("ok"))
            }

            it("pins claim, ghost, and transferred contracts") {
                let claim = try Self.loadObject("journeys/handoff/claim.json")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let mailbox = try decoder.decode(
                    JourneyMailboxEntry.self,
                    from: JSONSerialization.data(
                        withJSONObject: try Self.required(
                            claim["mailbox"] as? [String: Any],
                            "mailbox"
                        )
                    )
                )
                expect(mailbox.hasSupportedStateVersion).to(beTrue())
                expect(mailbox.kind).to(equal(.pending))
                expect(mailbox.envelope.executionState.plane).to(equal(.device))
                expect(mailbox.envelope.executionState.regionId)
                    .to(equal("device-region-1"))
                let epochRejected = try decoder.decode(
                    EventResponse.JourneyClaimAcknowledgement.self,
                    from: JSONSerialization.data(
                        withJSONObject: try Self.required(
                            claim["epochRejectedAck"] as? [String: Any],
                            "epochRejectedAck"
                        )
                    )
                )
                expect(epochRejected.accepted).to(beFalse())
                expect(epochRejected.epoch).to(beGreaterThan(mailbox.epoch))
                expect(epochRejected.reason).to(equal("stale_epoch"))
                expect(claim["unknownStateVersion"] as? Int)
                    .toNot(equal(JourneyStateEnvelope.currentVersion))
                expect(JourneyStatus.transferred.rawValue)
                    .to(equal(claim["terminalStatus"] as? String))

                let deviceToServer: [String: Any] = try Self.required(
                    claim["deviceToServer"] as? [String: Any],
                    "deviceToServer"
                )
                expect(deviceToServer["event"] as? String)
                    .to(equal(JourneyEvents.journeyHandoff))
                expect(deviceToServer["direction"] as? String)
                    .to(equal("device_to_server"))
                let vectors: [[String: Any]] = try Self.required(
                    deviceToServer["vectors"] as? [[String: Any]],
                    "deviceToServer.vectors"
                )
                for vector in vectors {
                    let name: String = try Self.required(
                        vector["name"] as? String,
                        "deviceToServer.vector.name"
                    )
                    let handoffObject: [String: Any] = try Self.required(
                        vector["handoff"] as? [String: Any],
                        "\(name).handoff"
                    )
                    let expectedProperties: [String: Any] = try Self.required(
                        vector["properties"] as? [String: Any],
                        "\(name).properties"
                    )
                    let expectedEnvelope: [String: Any] = try Self.required(
                        expectedProperties["envelope"] as? [String: Any],
                        "\(name).properties.envelope"
                    )
                    let handoff = try decoder.decode(
                        HandoffAction.self,
                        from: JSONSerialization.data(withJSONObject: handoffObject)
                    )
                    let envelope = try decoder.decode(
                        JourneyStateEnvelope.self,
                        from: JSONSerialization.data(withJSONObject: expectedEnvelope)
                    )
                    let journey = Journey(
                        id: expectedProperties["journey_id"] as? String,
                        experience: Self.makeExperience(),
                        distinctId: "handoff-fixture-user",
                        now: Date(timeIntervalSince1970: 0)
                    )
                    journey.epoch = (expectedProperties["epoch"] as! NSNumber).intValue
                    journey.executionState = envelope.executionState

                    let actualProperties = JourneyEvents.journeyHandoffProperties(
                        journey: journey,
                        envelope: envelope
                    )

                    expect(actualProperties as NSDictionary)
                        .to(equal(expectedProperties as NSDictionary), description: name)
                    expect(handoff.direction)
                        .to(equal(expectedProperties["direction"] as? String), description: name)
                    expect(envelope.executionState.regionId)
                        .to(equal(handoff.toRegionId), description: name)
                    expect(envelope.executionState.currentNodeId)
                        .to(equal(handoff.toNodeId), description: name)
                }

                let ghost = try Self.loadObject(
                    "journeys/ghost/superseded.json"
                )
                let fact = try decoder.decode(
                    JourneyDownFact.self,
                    from: JSONSerialization.data(
                        withJSONObject: try Self.required(
                            ghost["downFact"] as? [String: Any],
                            "downFact"
                        )
                    )
                )
                expect(fact.event).to(equal(.superseded))
                let expected = try Self.required(
                    ghost["expected"] as? [String: Any],
                    "expected"
                )
                expect(expected["emitsExit"] as? Bool).to(beFalse())
                expect(expected["recordsCompletion"] as? Bool).to(beFalse())
                expect(expected["requestsEffects"] as? Bool).to(beFalse())
            }

            it("matches the cross-plane time-window vectors") {
                let fixture = try Self.loadObject(
                    "journeys/time-window/cross-plane.json"
                )
                let timezone = TimeZone(
                    identifier: fixture["timezone"] as! String
                )!
                let formatter = ISO8601DateFormatter()
                for vector in fixture["vectors"] as! [[String: Any]] {
                    let now = formatter.date(
                        from: vector["now"] as! String
                    )!
                    let decision = TimeWindowMath.evaluate(
                        now: now,
                        startTime: vector["startTime"] as! String,
                        endTime: vector["endTime"] as! String,
                        daysOfWeek: vector["daysOfWeek"] as? [Int],
                        timezone: timezone
                    )
                    switch vector["decision"] as! String {
                    case "in_window":
                        expect(decision).to(equal(.inWindow))
                    case "malformed":
                        expect(decision).to(equal(.malformed))
                    case "pause":
                        expect(decision).to(equal(.pause(
                            until: formatter.date(
                                from: vector["until"] as! String
                            )!
                        )))
                    default:
                        fail("Unknown time-window fixture decision")
                    }
                }
            }

            it("matches the cross-plane experiment vectors") {
                let fixture = try Self.loadObject(
                    "journeys/experiment-resolution/cross-plane.json"
                )
                let variantIds = fixture["variantIds"] as! [String]
                for vector in fixture["vectors"] as! [[String: Any]] {
                    let assignment: ExperimentAssignment?
                    if let object = vector["assignment"] as? [String: Any] {
                        assignment = try JSONDecoder().decode(
                            ExperimentAssignment.self,
                            from: JSONSerialization.data(withJSONObject: object)
                        )
                    } else {
                        assignment = nil
                    }
                    let resolution = ExperimentResolver.resolve(
                        variantIds: variantIds,
                        assignment: assignment,
                        frozenVariantKey:
                            vector["frozenVariantKey"] as? String,
                        hasEmittedExposure:
                            vector["hasEmittedExposure"] as! Bool
                    )
                    expect(resolution.variantId ?? "<nil>")
                        .to(equal(
                            (vector["variantId"] as? String) ?? "<nil>"
                        ))
                    expect(resolution.shouldFreezeVariant)
                        .to(equal(vector["shouldFreezeVariant"] as? Bool))
                    expect(Self.exposureString(resolution.exposure))
                        .to(equal(vector["exposure"] as? String))
                    expect(resolution.errorAssignedVariantKey ?? "<nil>")
                        .to(equal(
                            (vector["errorAssignedVariantKey"] as? String)
                                ?? "<nil>"
                        ))
                }
            }

            it("preserves stable node ids for the either-node vocabulary") {
                let fixtureData = try Data(
                    contentsOf: Self.fixtureURL(
                        "journeys/conformance/either-vocabulary.json"
                    )
                )
                let fixtureHash = SHA256.hash(data: fixtureData)
                    .map { String(format: "%02x", $0) }
                    .joined()
                expect(fixtureHash).to(equal(
                    "373dffb2ed610370291ea9c1fa979d46ed61066535c3271fd1c295250a8d780d"
                ))
                let fixture = try Self.loadObject(
                    "journeys/conformance/either-vocabulary.json"
                )
                let actions = try JSONDecoder().decode(
                    [JourneyAction].self,
                    from: JSONSerialization.data(
                        withJSONObject: try Self.required(
                            fixture["actions"] as? [[String: Any]],
                            "actions"
                        )
                    )
                )
                let expected = try Self.required(
                    fixture["expected"] as? [String: Any],
                    "expected"
                )

                expect(Self.nodeIds(in: actions)).to(equal(
                    expected["decodedNodeIds"] as? [String]
                ))
            }

            it("preserves compiler node ids for every device action shape") {
                let path: [String: Any] = [
                    "kind": "path",
                    "viewModelName": "Main",
                    "path": "items",
                ]
                let actions: [[String: Any]] = [
                    ["type": "navigate", "nodeId": "device.navigate", "screenId": "screen"],
                    ["type": "back", "nodeId": "device.back"],
                    [
                        "type": "set_response_field",
                        "nodeId": "device.set-response-field",
                        "responseSchemaId": "response",
                        "key": "email",
                        "value": "person@example.com",
                    ],
                    [
                        "type": "submit_response",
                        "nodeId": "device.submit-response",
                        "responseSchemaId": "response",
                    ],
                    [
                        "type": "purchase",
                        "nodeId": "device.purchase",
                        "placementIndex": 0,
                        "productId": "product",
                    ],
                    ["type": "restore", "nodeId": "device.restore"],
                    [
                        "type": "request_notifications",
                        "nodeId": "device.request-notifications",
                    ],
                    [
                        "type": "request_permission",
                        "nodeId": "device.request-permission",
                        "permissionType": "camera",
                    ],
                    ["type": "request_tracking", "nodeId": "device.request-tracking"],
                    [
                        "type": "open_link",
                        "nodeId": "device.open-link",
                        "url": "https://example.com",
                    ],
                    [
                        "type": "start_animation",
                        "nodeId": "device.start-animation",
                        "animationId": "animation.press.fade",
                        "direction": "reverse",
                        "restart": false,
                    ],
                    ["type": "dismiss", "nodeId": "device.dismiss"],
                    [
                        "type": "call_delegate",
                        "nodeId": "device.call-delegate",
                        "message": "complete",
                    ],
                    [
                        "type": "set_view_model",
                        "nodeId": "device.set-view-model",
                        "path": path,
                        "value": 1,
                    ],
                    [
                        "type": "fire_trigger",
                        "nodeId": "device.fire-trigger",
                        "path": path,
                    ],
                    [
                        "type": "list_insert",
                        "nodeId": "device.list-insert",
                        "path": path,
                        "value": "first",
                    ],
                    [
                        "type": "list_remove",
                        "nodeId": "device.list-remove",
                        "path": path,
                        "index": 0,
                    ],
                    [
                        "type": "list_swap",
                        "nodeId": "device.list-swap",
                        "path": path,
                        "indexA": 0,
                        "indexB": 1,
                    ],
                    [
                        "type": "list_move",
                        "nodeId": "device.list-move",
                        "path": path,
                        "from": 0,
                        "to": 1,
                    ],
                    [
                        "type": "list_set",
                        "nodeId": "device.list-set",
                        "path": path,
                        "index": 0,
                        "value": "updated",
                    ],
                    [
                        "type": "list_clear",
                        "nodeId": "device.list-clear",
                        "path": path,
                    ],
                ]
                let decoded = try JSONDecoder().decode(
                    [JourneyAction].self,
                    from: JSONSerialization.data(withJSONObject: actions)
                )

                expect(decoded.compactMap(\.nodeId)).to(equal(
                    actions.compactMap { $0["nodeId"] as? String }
                ))
                expect(decoded.contains { action in
                    if case .unknown(let type, _) = action {
                        return type == "start_animation"
                    }
                    return false
                }).to(beFalse())
            }
        }
    }

    private enum FixtureError: Error {
        case missing(String)
    }

    private static func required<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw FixtureError.missing(label) }
        return value
    }

    private static func loadObject(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL(path))
        return try required(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            path
        )
    }

    private static func fixtureURL(_ path: String) -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("fixtures/\(path)")
    }

    private static func nodeIds(in actions: [JourneyAction]) -> [String] {
        actions.flatMap { action in
            let nested: [JourneyAction]
            switch action {
            case .condition(let condition):
                nested = condition.branches.flatMap(\.actions)
                    + (condition.defaultActions ?? [])
            case .experiment(let experiment):
                nested = experiment.variants.flatMap(\.actions)
            case .timeWindow(let timeWindow):
                nested = timeWindow.successActions ?? []
            case .waitUntil(let waitUntil):
                nested = (waitUntil.successActions ?? [])
                    + (waitUntil.timeoutActions ?? [])
            default:
                nested = []
            }
            return (action.nodeId.map { [$0] } ?? []) + nodeIds(in: nested)
        }
    }

    private static func makeExperience() -> Experience {
        Experience(
            id: "experience-1",
            versionId: "flow-version-1",
            name: "Experience",
            reentry: .everyTime,
            publishedAt: "2026-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(eventName: "app_opened", condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }

    private static func exposureString(
        _ exposure: ExperimentResolver.Exposure
    ) -> String {
        switch exposure {
        case .none:
            return "none"
        case .real(let source, let holdout):
            return "real:\(source):\(holdout)"
        case .fallback(let source):
            return "fallback:\(source)"
        }
    }
}
