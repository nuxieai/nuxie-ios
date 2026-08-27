import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

/// Runs the language-neutral conformance vectors in `fixtures/` (repo root).
///
/// These vectors — not this Swift implementation — are the contract shared
/// with the Android SDK (and future executors). Loading goes through the repo
/// checkout via #filePath so the same JSON files can be consumed verbatim by
/// other runners without resource-bundling gymnastics.
final class ConformanceVectorTests: XCTestCase {

    private static var fixturesRoot: URL {
        // Tests/NuxieUnitTests/Conformance/ConformanceVectorTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // strip filename → Fixtures/
            .deletingLastPathComponent()  // NuxieUnitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("fixtures")
    }

    private struct Suite: Decodable {
        let suite: String
        let version: Int
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let event: EventInput
        let expect: [String: AnyDecodable]
        let expectPropertiesJSON: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case event
            case expect
            case expectPropertiesJSON = "expect_properties_json"
        }
    }

    private struct EventInput: Decodable {
        let id: String
        let name: String
        let distinct_id: String
        let timestamp: String
        let properties: [String: AnyDecodable]?
    }

    private struct AnyDecodable: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { value = v }
            else if let v = try? c.decode(Int.self) { value = v }
            else if let v = try? c.decode(Double.self) { value = v }
            else if let v = try? c.decode(String.self) { value = v }
            else if let v = try? c.decode([String: AnyDecodable].self) { value = v.mapValues(\.value) }
            else if let v = try? c.decode([AnyDecodable].self) { value = v.map(\.value) }
            else { value = NSNull() }
        }
    }

    private func loadSuite(_ relativePath: String) throws -> Suite {
        let url = Self.fixturesRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(Suite.self, from: data)
        XCTAssertEqual(suite.version, 1, "Unknown fixture version in \(suite.suite) — runners must fail, not skip")
        return suite
    }

    func testExperienceReleaseSegmentTriggerVector() throws {
        let vectorURL = Self.fixturesRoot.appendingPathComponent(
            "experience-release-descriptor/segment-trigger.json"
        )
        let vector = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: vectorURL)) as? [String: Any]
        )
        XCTAssertEqual(vector["suite"] as? String, "experience-release-segment-trigger-v1")
        XCTAssertEqual((vector["version"] as? NSNumber)?.intValue, 1)

        let envelopeURL = Self.fixturesRoot.appendingPathComponent(
            "experience-release-descriptor/envelope.json"
        )
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: envelopeURL)) as? [String: Any]
        )
        let descriptorBase64 = try XCTUnwrap(envelope["descriptorBytesBase64"] as? String)
        let descriptorData = try XCTUnwrap(Data(base64Encoded: descriptorBase64))
        var descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descriptorData) as? [String: Any]
        )
        var enrollment = try XCTUnwrap(descriptor["enrollment"] as? [String: Any])
        enrollment["trigger"] = try XCTUnwrap(vector["trigger"] as? [String: Any])
        enrollment["requiredSegmentIds"] = try XCTUnwrap(vector["requiredSegmentIds"] as? [String])
        descriptor["enrollment"] = enrollment

        XCTAssertNoThrow(try ExperienceReleaseDescriptorSchemaValidator.validate(descriptor))

        enrollment["trigger"] = ["type": "segment", "allOf": ["seg_a", "seg_b"]]
        descriptor["enrollment"] = enrollment
        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(descriptor))
    }

    func testExperienceReleaseProfileWireVector() throws {
        struct ProfileSuite: Decodable {
            struct Expectation: Decodable {
                let activeExperienceVersionId: String
                let activePublishedAtSeq: Int
                let pinnedExperienceVersionId: String
                let pinnedBuildId: String
            }

            let suite: String
            let version: Int
            let wire: ExperienceReleaseProfile
            let expect: Expectation
        }

        let url = Self.fixturesRoot.appendingPathComponent(
            "experience-release-profile-v1/profile.json"
        )
        let data = try Data(contentsOf: url)
        let suite = try JSONDecoder().decode(ProfileSuite.self, from: data)

        XCTAssertEqual(suite.suite, "experience-release-profile-v1")
        XCTAssertEqual(suite.version, 1)
        XCTAssertEqual(
            suite.wire.active.first?.locator.experienceVersionId,
            suite.expect.activeExperienceVersionId
        )
        XCTAssertEqual(
            suite.wire.active.first?.locator.publishedAtSeq,
            suite.expect.activePublishedAtSeq
        )
        XCTAssertEqual(
            suite.wire.pinned.first?.locator.experienceVersionId,
            suite.expect.pinnedExperienceVersionId
        )
        XCTAssertEqual(
            suite.wire.pinned.first?.locator.buildId,
            suite.expect.pinnedBuildId
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let expectedWire = try XCTUnwrap(root["wire"] as? [String: Any])
        let encodedWire = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(suite.wire)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            NSDictionary(dictionary: encodedWire),
            NSDictionary(dictionary: expectedWire)
        )
    }

    func testTriggerResultEncodingVectors() throws {
        struct EncodingSuite: Decodable {
            let suite: String
            let version: Int
            let vectors: [EncodingVector]
        }
        struct EncodingVector: Decodable {
            let name: String
            let result: [String: AnyDecodable]
            let expect: [String: AnyDecodable]
        }

        let url = Self.fixturesRoot.appendingPathComponent("encodings/trigger-result.json")
        let suite = try JSONDecoder().decode(EncodingSuite.self, from: Data(contentsOf: url))
        XCTAssertEqual(suite.version, 1)

        for vector in suite.vectors {
            let kind = vector.result["kind"]?.value as? String
            let result: TriggerResult
            switch kind {
            case "noMatch":
                result = .noMatch
            case "allowed":
                result = .allowed
            case "denied":
                result = .denied
            case "journeyCompleted":
                result = .journeyCompleted(JourneyUpdate(
                    journeyId: vector.result["journey_id"]?.value as? String ?? "",
                    experienceId: "c-1",
                    experienceVersion: nil,
                    exitReason: JourneyExitReason(rawValue: vector.result["exit_reason"]?.value as? String ?? "") ?? .completed,
                    goalMet: vector.result["goal_met"]?.value as? Bool ?? false
                ))
            case "error":
                let rawCode = vector.result["code"]?.value as? String ?? ""
                guard let code = TriggerError.Code(rawValue: rawCode) else {
                    XCTFail("[\(vector.name)] unknown trigger error code \(rawCode)")
                    continue
                }
                result = .error(TriggerError(code: code, message: ""))
            default:
                XCTFail("[\(vector.name)] unknown result kind \(kind ?? "nil")"); continue
            }

            let wire = result.wireValue
            for (key, expected) in vector.expect {
                XCTAssertEqual(wire[key], expected.value as? String, "[\(vector.name)] \(key)")
            }
            // No extra keys beyond the expectation (lossless, stable projection)
            XCTAssertEqual(wire.count, vector.expect.count, "[\(vector.name)] extra wire keys")
        }
    }

    func testBatchItemEncodingVectors() throws {
        let suite = try loadSuite("events/batch-item-encoding.json")
        let iso = ISO8601DateFormatter()

        for vector in suite.vectors {
            let input = vector.event
            guard let timestamp = iso.date(from: input.timestamp) else {
                XCTFail("[\(vector.name)] unparseable timestamp \(input.timestamp)")
                continue
            }
            let event = NuxieEvent(
                id: input.id,
                name: input.name,
                distinctId: input.distinct_id,
                properties: input.properties?.mapValues(\.value) ?? [:],
                timestamp: timestamp
            )

            let item = BatchEventItem(event: event)

            if let expectedPropertiesJSON = vector.expectPropertiesJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let propertiesData = try encoder.encode(item.properties ?? [:])
                XCTAssertEqual(
                    String(decoding: propertiesData, as: UTF8.self),
                    expectedPropertiesJSON,
                    "[\(vector.name)] serialized properties"
                )
            }

            for (key, expected) in vector.expect {
                switch key {
                case "event":
                    XCTAssertEqual(item.event, expected.value as? String, "[\(vector.name)] event")
                case "distinct_id":
                    XCTAssertEqual(item.distinctId, expected.value as? String, "[\(vector.name)] distinct_id")
                case "anon_distinct_id":
                    XCTAssertEqual(item.anonDistinctId, expected.value as? String, "[\(vector.name)] anon_distinct_id")
                case "idempotency_key":
                    XCTAssertEqual(item.idempotencyKey, expected.value as? String, "[\(vector.name)] idempotency_key")
                case "timestamp":
                    XCTAssertEqual(item.timestamp, expected.value as? String, "[\(vector.name)] timestamp")
                case "value":
                    let expectedDouble = (expected.value as? Int).map(Double.init) ?? expected.value as? Double
                    XCTAssertEqual(item.value, expectedDouble, "[\(vector.name)] value")
                case "entity_id":
                    XCTAssertEqual(item.entityId, expected.value as? String, "[\(vector.name)] entity_id")
                case "properties":
                    guard let expectedProps = expected.value as? [String: Any] else {
                        XCTFail("[\(vector.name)] malformed expected properties"); continue
                    }
                    for (propKey, propValue) in expectedProps {
                        let actual = item.properties?[propKey]?.value
                        XCTAssertEqual(
                            String(describing: actual ?? "nil"),
                            String(describing: propValue),
                            "[\(vector.name)] properties.\(propKey)"
                        )
                    }
                default:
                    XCTFail("[\(vector.name)] unhandled expectation key '\(key)' — extend the runner")
                }
            }
        }
    }

    func testDeliveryDispositionFixtureCoversRequiredHazards() throws {
        let url = Self.fixturesRoot.appendingPathComponent(
            "events/delivery-disposition.json"
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(root["suite"] as? String, "events/delivery-disposition")
        XCTAssertEqual(root["version"] as? Int, 1)
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(Set(vectors.compactMap { $0["name"] as? String }), Set([
            "rate limit honors retry after",
            "authentication failure marks sdk unhealthy",
            "oversized batch splits",
            "malformed partial response acknowledges nothing",
            "mixed valid and invalid batch acknowledges valid indexes",
            "poison event isolation preserves valid neighbors",
        ]))

        for vector in vectors {
            let name = try XCTUnwrap(vector["name"] as? String)
            let response = try XCTUnwrap(vector["response"] as? [String: Any])
            let expectation = try XCTUnwrap(vector["expect"] as? [String: Any])
            let statusCode = try XCTUnwrap(response["status_code"] as? Int)

            switch name {
            case "rate limit honors retry after":
                XCTAssertEqual(statusCode, 429)
                XCTAssertEqual(response["retry_after"] as? String, "60")
                XCTAssertEqual(expectation["disposition"] as? String, "retry")
                XCTAssertEqual(expectation["backoff_capped"] as? Bool, true)
            case "authentication failure marks sdk unhealthy":
                XCTAssertEqual(statusCode, 401)
                XCTAssertEqual(
                    expectation["disposition"] as? String,
                    "unhealthy_authentication"
                )
                XCTAssertEqual(expectation["retry_cadence"] as? String, "periodic")
            case "oversized batch splits":
                XCTAssertEqual(statusCode, 413)
                XCTAssertEqual((vector["batch"] as? [String])?.count, 4)
                XCTAssertEqual(expectation["next_batch_size"] as? Int, 2)
            case "malformed partial response acknowledges nothing":
                XCTAssertEqual(statusCode, 200)
                XCTAssertEqual(response["total"] as? Int, 4)
                XCTAssertEqual(response["error_indexes"] as? [Int], [7])
                XCTAssertEqual(expectation["disposition"] as? String, "retry")
            case "mixed valid and invalid batch acknowledges valid indexes":
                XCTAssertEqual(statusCode, 200)
                XCTAssertEqual(response["processed"] as? Int, 2)
                XCTAssertEqual(response["failed"] as? Int, 1)
                XCTAssertEqual(response["error_indexes"] as? [Int], [1])
                XCTAssertEqual(expectation["disposition"] as? String, "partial")
            case "poison event isolation preserves valid neighbors":
                XCTAssertEqual(statusCode, 422)
                XCTAssertEqual(expectation["disposition"] as? String, "split")
                XCTAssertEqual(expectation["dead_lettered"] as? [String], ["poison"])
            default:
                XCTFail("Unhandled delivery disposition fixture: \(name)")
            }

            if expectation["acknowledged"] != nil {
                XCTAssertNotNil(expectation["acknowledged"] as? [String])
            }
        }
    }

    func testJourneyParkingVectors() throws {
        let url = Self.fixturesRoot.appendingPathComponent(
            "journeys/parking/emission.json"
        )
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual(fixture["suite"] as? String, "journeys/parking")
        let journeyId = try XCTUnwrap(fixture["journeyId"] as? String)
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: try XCTUnwrap(fixture["now"] as? String)
            )
        )
        let vectors = try XCTUnwrap(
            fixture["vectors"] as? [[String: Any]]
        )

        for vector in vectors {
            let name = try XCTUnwrap(vector["name"] as? String)
            let expected = try XCTUnwrap(
                vector["expected"] as? [String: Any]
            )
            let executionState = try XCTUnwrap(
                vector["executionState"] as? [String: Any]
            )
            var journey = JourneySnapshot(
                id: journeyId,
                experience: Self.makeFixtureExperience(),
                distinctId: "parking-fixture-user",
                now: now
            )
            journey.epoch = try XCTUnwrap(vector["epoch"] as? Int)
            journey.context = (vector["context"] as? [String: Any] ?? [:])
                .mapValues(AnyCodable.init)
            journey.executionState.regionId = executionState["regionId"] as? String
            journey.executionState.currentNodeId =
                executionState["currentNodeId"] as? String

            var pendingDeadlineAt: Date?
            if let pending = executionState["pendingAction"] as? [String: Any] {
                let resumeAt = try XCTUnwrap(
                    ISO8601DateFormatter().date(
                        from: try XCTUnwrap(pending["resumeAt"] as? String)
                    )
                )
                let startedAt = try XCTUnwrap(
                    ISO8601DateFormatter().date(
                        from: try XCTUnwrap(pending["startedAt"] as? String)
                    )
                )
                journey.executionState.pendingAction = JourneyPendingAction(
                    handlerId: try XCTUnwrap(
                        pending["handlerId"] as? String
                    ),
                    screenId: nil,
                    componentId: nil,
                    actionIndex: try XCTUnwrap(
                        pending["actionIndex"] as? Int
                    ),
                    kind: try XCTUnwrap(
                        JourneyPendingActionKind(
                            rawValue: try XCTUnwrap(
                                pending["kind"] as? String
                            )
                        )
                    ),
                    resumeAt: resumeAt,
                    condition: nil,
                    maxTimeMs: nil,
                    startedAt: startedAt,
                    resumeActions: nil
                )
                pendingDeadlineAt = resumeAt
            }

            let reason = try XCTUnwrap(
                JourneyParkingReason(
                    rawValue: try XCTUnwrap(vector["reason"] as? String)
                )
            )
            let properties = JourneyEvents.journeyParkedProperties(
                journey: journey,
                reason: reason,
                pendingDeadlineAt: pendingDeadlineAt
            )
            XCTAssertEqual(
                JourneyEvents.journeyParked,
                expected["event"] as? String,
                name
            )
            XCTAssertEqual(
                properties["journey_id"] as? String,
                expected["journeyId"] as? String,
                name
            )
            XCTAssertEqual(
                properties["epoch"] as? Int,
                expected["epoch"] as? Int,
                name
            )
            XCTAssertEqual(
                properties["reason"] as? String,
                expected["reason"] as? String,
                name
            )
            XCTAssertEqual(
                properties["pending_deadline_at"] as? String,
                expected["pendingDeadlineAt"] as? String,
                name
            )
            let checkpoint = try XCTUnwrap(
                properties["checkpoint"] as? [String: Any],
                name
            )
            let checkpointExecutionState = try XCTUnwrap(
                checkpoint["executionState"] as? [String: Any],
                name
            )
            XCTAssertEqual(
                checkpoint["stateVersion"] as? Int,
                expected["checkpointStateVersion"] as? Int,
                name
            )
            XCTAssertEqual(
                checkpointExecutionState["plane"] as? String,
                expected["checkpointPlane"] as? String,
                name
            )
            XCTAssertEqual(
                checkpointExecutionState["currentNodeId"] as? String,
                expected["checkpointNodeId"] as? String,
                name
            )
        }
    }

    func testJourneyDismissalVectors() throws {
        let url = Self.fixturesRoot.appendingPathComponent(
            "journeys/dismissal/host.json"
        )
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual(fixture["suite"] as? String, "journeys/dismissal")
        let journeyId = try XCTUnwrap(fixture["journeyId"] as? String)
        let epoch = try XCTUnwrap(fixture["epoch"] as? Int)
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: try XCTUnwrap(fixture["now"] as? String)
            )
        )
        let vectors = try XCTUnwrap(
            fixture["vectors"] as? [[String: Any]]
        )

        for vector in vectors {
            let name = try XCTUnwrap(vector["name"] as? String)
            let reason = try XCTUnwrap(
                JourneyExitReason(
                    rawValue: try XCTUnwrap(vector["reason"] as? String)
                )
            )
            let dismissedBy = (vector["dismissedBy"] as? String)
                .flatMap(JourneyDismissalSource.init(rawValue:))
            let expected = try XCTUnwrap(
                vector["expected"] as? [String: Any]
            )
            var journey = JourneySnapshot(
                id: journeyId,
                experience: Self.makeFixtureExperience(),
                distinctId: "dismissal-fixture-user",
                now: now
            )
            journey.epoch = epoch

            XCTAssertEqual(
                JourneyEvents.journeyExitedProperties(
                    journey: journey,
                    reason: reason,
                    at: now,
                    dismissedBy: dismissedBy
                ) as NSDictionary,
                expected as NSDictionary,
                name
            )
        }
    }

    func testJourneyTakeoverVectors() throws {
        let url = Self.fixturesRoot.appendingPathComponent(
            "journeys/takeover/claimable.json"
        )
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual(fixture["suite"] as? String, "journeys/takeover")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let mailbox = try decoder.decode(
            JourneyMailboxEntry.self,
            from: JSONSerialization.data(
                withJSONObject: try XCTUnwrap(
                    fixture["mailbox"] as? [String: Any]
                )
            )
        )
        let accepted = try decoder.decode(
            EventResponse.JourneyClaimAcknowledgement.self,
            from: JSONSerialization.data(
                withJSONObject: try XCTUnwrap(
                    fixture["acceptedAck"] as? [String: Any]
                )
            )
        )
        let rejected = try decoder.decode(
            EventResponse.JourneyOwnershipAcknowledgement.self,
            from: JSONSerialization.data(
                withJSONObject: try XCTUnwrap(
                    fixture["originalDeviceEpochRejection"]
                        as? [String: Any]
                )
            )
        )
        let expected = try XCTUnwrap(
            fixture["expected"] as? [String: Any]
        )

        XCTAssertEqual(mailbox.kind, .claimable)
        XCTAssertTrue(mailbox.hasSupportedStateVersion)
        XCTAssertEqual(mailbox.envelope.executionState.plane, .device)
        XCTAssertEqual(mailbox.envelope.responseSession?.version, 4)
        XCTAssertEqual(
            mailbox.envelope.executionState.pendingAction?.responseVersion,
            4
        )
        XCTAssertEqual(mailbox.resumePoint?.nodeId, "question-3")
        XCTAssertEqual(
            mailbox.resumePoint?.checkpointAt,
            ISO8601DateFormatter().date(
                from: try XCTUnwrap(expected["checkpointAt"] as? String)
            )
        )
        XCTAssertEqual(mailbox.epoch, expected["offeredEpoch"] as? Int)
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.epoch, expected["claimedEpoch"] as? Int)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.reason, "stale_epoch")
        XCTAssertEqual(
            JourneyEvents.journeyClaimed,
            expected["claimEvent"] as? String
        )
        XCTAssertEqual(
            JourneyEvents.journeyClaimedProperties(
                journeyId: mailbox.journeyId,
                epoch: mailbox.epoch,
                claimant: "device-b"
            )["epoch"] as? Int,
            expected["offeredEpoch"] as? Int
        )
        XCTAssertEqual(
            expected["takeoverUsesRelaunchRestore"] as? Bool,
            true
        )
        XCTAssertEqual(
            expected["pastDuePendingActionSchedulesImmediately"] as? Bool,
            true
        )
        XCTAssertEqual(
            expected["originalDeviceDiscardsOnEpochRejection"] as? Bool,
            true
        )
    }

    func testJourneySeizureRaceVector() throws {
        let url = Self.fixturesRoot.appendingPathComponent(
            "journeys/seizure-race/device-handoff-wins.json"
        )
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        XCTAssertEqual(fixture["version"] as? Int, 1)
        XCTAssertEqual(fixture["suite"] as? String, "journeys/seizure-race")
        let handoff = try XCTUnwrap(
            fixture["deviceHandoff"] as? [String: Any]
        )
        let expectedProperties = try XCTUnwrap(
            handoff["properties"] as? [String: Any]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            JourneyStateEnvelope.self,
            from: JSONSerialization.data(
                withJSONObject: try XCTUnwrap(
                    expectedProperties["envelope"] as? [String: Any]
                )
            )
        )
        var journey = JourneySnapshot(
            id: expectedProperties["journey_id"] as? String,
            experience: Self.makeFixtureExperience(),
            distinctId: "seizure-race-user",
            now: Date(timeIntervalSince1970: 0)
        )
        journey.epoch = try XCTUnwrap(expectedProperties["epoch"] as? Int)
        journey.applyStateEnvelope(envelope, epoch: journey.epoch)

        XCTAssertEqual(
            JourneyEvents.journeyHandoff,
            handoff["event"] as? String
        )
        XCTAssertEqual(
            JourneyEvents.journeyHandoffProperties(
                journey: journey,
                envelope: envelope
            ) as NSDictionary,
            expectedProperties as NSDictionary
        )

        let ack = try decoder.decode(
            EventResponse.JourneyOwnershipAcknowledgement.self,
            from: JSONSerialization.data(
                withJSONObject: try XCTUnwrap(
                    fixture["handoffAck"] as? [String: Any]
                )
            )
        )
        let seizure = try XCTUnwrap(
            fixture["seizureAttempt"] as? [String: Any]
        )
        let expected = try XCTUnwrap(
            fixture["expected"] as? [String: Any]
        )
        XCTAssertTrue(ack.accepted)
        XCTAssertEqual(ack.epoch, expected["authoritativeEpoch"] as? Int)
        XCTAssertEqual(seizure["accepted"] as? Bool, false)
        XCTAssertEqual(
            seizure["offeredEpoch"] as? Int,
            expectedProperties["epoch"] as? Int
        )
        XCTAssertEqual(seizure["expectedEpoch"] as? Int, ack.epoch)
        XCTAssertEqual(
            JourneyStatus.transferred.rawValue,
            expected["deviceTerminalStatus"] as? String
        )
        XCTAssertEqual(expected["winner"] as? String, "device_handoff")
        XCTAssertEqual(expected["effectExecutions"] as? Int, 1)
    }

    // MARK: - IR eval vectors

    /// In-memory adapters serving fixture state to the interpreter.
    private struct FixtureUserProps: IRUserProps {
        let props: [String: Any]
        func userProperty(for key: String) async -> Any? { props[key] }
    }

    private struct FixtureEventRow {
        let name: String
        let timestamp: Date
        let properties: [String: Any]
    }

    private struct FixtureEvents: IREventQueries {
        let rows: [FixtureEventRow]

        func historyCoverage() async -> EventHistoryCoverage { .complete }

        private func matching(
            name: String, since: Date?, until: Date?, predicate: IRPredicate?
        ) -> [FixtureEventRow] {
            rows.filter { row in
                guard row.name == name else { return false }
                if let since, row.timestamp < since { return false }
                if let until, row.timestamp > until { return false }
                if let predicate, !PredicateEval.eval(predicate, props: row.properties) {
                    return false
                }
                return true
            }
        }

        func exists(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Bool {
            !matching(name: name, since: since, until: until, predicate: predicate).isEmpty
        }
        func count(name: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Int {
            matching(name: name, since: since, until: until, predicate: predicate).count
        }
        func firstTime(name: String, where predicate: IRPredicate?) async -> Date? {
            matching(name: name, since: nil, until: nil, predicate: predicate)
                .map(\.timestamp).min()
        }
        func lastTime(name: String, where predicate: IRPredicate?) async -> Date? {
            matching(name: name, since: nil, until: nil, predicate: predicate)
                .map(\.timestamp).max()
        }
        func aggregate(_ agg: Aggregate, name: String, prop: String, since: Date?, until: Date?, where predicate: IRPredicate?) async -> Double? {
            let values = matching(name: name, since: since, until: until, predicate: predicate)
                .compactMap { Coercion.asNumber($0.properties[prop]) }
            guard !values.isEmpty else { return nil }
            switch agg {
            case .sum: return values.reduce(0, +)
            case .avg: return values.reduce(0, +) / Double(values.count)
            case .min: return values.min()
            case .max: return values.max()
            case .unique: return Double(Set(values).count)
            }
        }
        func inOrder(steps: [StepQuery], overallWithin: TimeInterval?, perStepWithin: TimeInterval?, since: Date?, until: Date?) async -> Bool { false }
        func activePeriods(name: String, period: Period, total: Int, min: Int, where predicate: IRPredicate?) async -> Bool { false }
        func stopped(name: String, inactiveFor: TimeInterval, where predicate: IRPredicate?) async -> Bool { false }
        func restarted(name: String, inactiveFor: TimeInterval, within: TimeInterval, where predicate: IRPredicate?) async -> Bool { false }
    }

    private struct FixtureSegments: IRSegmentQueries {
        let members: Set<String>
        let enteredAt: [String: Date]
        func isMember(_ segmentId: String) async -> Bool { members.contains(segmentId) }
        func enteredAt(_ segmentId: String) async -> Date? { enteredAt[segmentId] }
    }

    func testIREvalVectors() async throws {
        struct IRSuite: Decodable {
            let suite: String
            let version: Int
            let now: String
            let distinct_id: String
            let user: [String: AnyDecodable]
            let events: [IREventInput]
            let segments: IRSegmentState
            let trigger_event: IRTriggerEvent
            let vectors: [IRVector]
        }
        struct IREventInput: Decodable {
            let name: String
            let timestamp: String
            let properties: [String: AnyDecodable]
        }
        struct IRSegmentState: Decodable {
            let member_of: [String]
            let entered_at: [String: String]
        }
        struct IRTriggerEvent: Decodable {
            let name: String
            let properties: [String: AnyDecodable]
        }
        struct IRVector: Decodable {
            let name: String
            let envelope: IREnvelope
            let expect: Bool?
            let expect_supported: Bool?
        }

        let url = Self.fixturesRoot.appendingPathComponent("ir/eval-vectors.json")
        let suite = try JSONDecoder().decode(IRSuite.self, from: Data(contentsOf: url))
        XCTAssertEqual(suite.version, 1, "Unknown ir-eval fixture version — runners must fail, not skip")

        let iso = ISO8601DateFormatter()
        guard let now = iso.date(from: suite.now) else {
            XCTFail("unparseable suite now \(suite.now)"); return
        }

        let user = FixtureUserProps(props: suite.user.mapValues(\.value))
        let events = FixtureEvents(rows: try suite.events.map { input in
            guard let ts = iso.date(from: input.timestamp) else {
                throw NSError(domain: "fixture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "unparseable event timestamp \(input.timestamp)"
                ])
            }
            return FixtureEventRow(
                name: input.name, timestamp: ts,
                properties: input.properties.mapValues(\.value))
        })
        let segments = FixtureSegments(
            members: Set(suite.segments.member_of),
            enteredAt: suite.segments.entered_at.compactMapValues(iso.date(from:))
        )
        let triggerEvent = NuxieEvent(
            name: suite.trigger_event.name,
            distinctId: suite.distinct_id,
            properties: suite.trigger_event.properties.mapValues(\.value),
            timestamp: now
        )

        for vector in suite.vectors {
            if let expectSupported = vector.expect_supported {
                XCTAssertEqual(
                    vector.envelope.isSupportedByThisEngine, expectSupported,
                    "[\(vector.name)] engine_min gate"
                )
                if !expectSupported { continue }
            }

            guard let expected = vector.expect else {
                XCTFail("[\(vector.name)] supported vector without an expectation")
                continue
            }

            let ctx = EvalContext(
                now: now,
                user: user,
                events: events,
                segments: segments,
                event: triggerEvent
            )
            let interpreter = IRInterpreter(ctx: ctx)
            let result = (try? await interpreter.evalBool(vector.envelope.expr)) ?? false
            XCTAssertEqual(result, expected, "[\(vector.name)]")
        }
    }

    func testResponseFieldIRVectors() async throws {
        struct Suite: Decodable {
            let version: Int
            let now: String
            let responseSession: ResponseSessionSnapshot
            let vectors: [Vector]
        }
        struct Vector: Decodable {
            let name: String
            let expr: IRExpr
            let expect: Bool
        }

        let url = Self.fixturesRoot.appendingPathComponent(
            "ir/response-field-conformance.json"
        )
        let suite = try JSONDecoder().decode(
            Suite.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(suite.version, 1)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: suite.now))
        let interpreter = IRInterpreter(
            ctx: EvalContext(
                now: now,
                responseSession: suite.responseSession
            )
        )

        for vector in suite.vectors {
            let result = try await interpreter.evalBool(vector.expr)
            XCTAssertEqual(
                result,
                vector.expect,
                vector.name
            )
        }
    }

    private static func makeFixtureExperience() -> Experience {
        Experience(
            id: "experience-1",
            versionId: "flow-version-1",
            name: "Fixture",
            reentry: .everyTime,
            publishedAt: "2026-07-28T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }
}
