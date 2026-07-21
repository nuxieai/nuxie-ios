import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Runs the golden-journey conformance vectors in `fixtures/journeys/`
/// (repo root) against a REAL JourneyService: wire-format campaign + flow
/// decode through the production Codable path, a scripted timeline drives
/// events, and the vectors assert the ordered subsequence of tracked events
/// plus the surviving journey count. These vectors — not this runner — are
/// the cross-SDK contract (shared with Android).
final class GoldenJourneyTests: XCTestCase {

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Fixtures/
            .deletingLastPathComponent()  // NuxieIntegrationTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("fixtures")
    }

    // MARK: - Suite model

    private struct Suite: Decodable {
        let suite: String
        let version: Int
        let distinct_id: String
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let campaign: RawJSON
        let flow: RawJSON
        /// Optional server experiment assignments (experimentKey → assignment),
        /// decoded through the production `ExperimentAssignment` wire type and
        /// installed in the profile before the timeline runs.
        let experiments: RawJSON?
        let timeline: [TimelineEntry]
        let expect: Expectation
    }

    /// One scripted timeline step. Exactly one step kind per entry; an entry
    /// with zero or multiple step keys — or an unknown step kind — must FAIL
    /// decoding. A runner that silently skipped steps it does not understand
    /// would pass vectors it never actually executed.
    private enum TimelineEntry: Decodable {
        case track(TrackEntry)
        case advanceClock(seconds: Double)
        case assertAbsent([String])
        case setExperiments(RawJSON)

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "timeline entries must contain exactly one step key"
                ))
            }
            switch key.stringValue {
            case "track":
                self = .track(try container.decode(TrackEntry.self, forKey: key))
            case "advance_clock_seconds":
                self = .advanceClock(seconds: try container.decode(Double.self, forKey: key))
            case "assert_absent":
                self = .assertAbsent(try container.decode([String].self, forKey: key))
            case "set_experiments":
                self = .setExperiments(try container.decode(RawJSON.self, forKey: key))
            default:
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown timeline step kind: \(key.stringValue)"
                ))
            }
        }
    }

    private struct TrackEntry: Decodable {
        let name: String
        let properties: [String: AnyDecodable]?
    }

    private struct Expectation: Decodable {
        let ordered_event_subsequence: [String]?
        let forbidden_events: [String]?
        let event_properties: [String: [String: AnyDecodable]]?
        let event_counts: [String: Int]?
        let active_journeys_after: Int?
    }

    /// Captures a JSON subtree verbatim so it can be re-encoded and decoded
    /// through the production wire types (Campaign, RemoteFlow).
    private struct RawJSON: Decodable {
        let data: Data
        init(from decoder: Decoder) throws {
            let value = try AnyDecodable(from: decoder).value
            data = try JSONSerialization.data(withJSONObject: value)
        }
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

    // MARK: - Runner

    func testGoldenJourneyVectors() async throws {
        let url = Self.fixturesRoot.appendingPathComponent("journeys/golden-journeys.json")
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: url))
        XCTAssertEqual(suite.version, 2, "Unknown golden-journey fixture version — runners must fail, not skip")

        for vector in suite.vectors {
            try await runVector(vector, distinctId: suite.distinct_id)
        }
    }

    private func runVector(_ vector: Vector, distinctId: String) async throws {
        // Wire-format decode through the production types — a fixture that
        // fails to decode is a contract violation, not a test setup issue.
        let campaign: Campaign
        let screens: RemoteFlow
        var experiments: [String: ExperimentAssignment]?
        do {
            campaign = try JSONDecoder().decode(Campaign.self, from: vector.campaign.data)
            screens = try JSONDecoder().decode(RemoteFlow.self, from: vector.flow.data)
            if let rawExperiments = vector.experiments {
                experiments = try JSONDecoder().decode(
                    [String: ExperimentAssignment].self, from: rawExperiments.data
                )
            }
        } catch {
            XCTFail("[\(vector.name)] wire decode failed: \(error)")
            return
        }

        // Real journey service over mock transport/renderer
        let mocks = MockFactory.shared
        await mocks.resetAll()
        mocks.identityService.setDistinctId(distinctId)

        let journeyStore = MockJourneyStore()
        let service = mocks.makeJourneyService(journeyStore: journeyStore)

        func installProfile(experiments: [String: ExperimentAssignment]?) async throws {
            mocks.profileService.setProfileResponse(ProfileResponse(
                campaigns: [campaign],
                segments: [],
                flows: [screens],
                userProperties: nil,
                experiments: experiments,
                features: nil,
                journeys: nil
            ))
            _ = try await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        mocks.flowService.mockExperiences[screens.id] = Experience(screens: screens)
        try await installProfile(experiments: experiments)

        await service.initialize()

        // Drive the timeline
        for entry in vector.timeline {
            switch entry {
            case .track(let track):
                // Events carry the SDK clock so clock-advance vectors control
                // event-time semantics (goal conversion windows compare the
                // event's timestamp, not evaluation time).
                let event = NuxieEvent(
                    name: track.name,
                    distinctId: distinctId,
                    properties: track.properties?.mapValues(\.value) ?? [:],
                    timestamp: mocks.dateProvider.now()
                )
                // Mirror the production pipeline: an event is committed to
                // history before journey routing sees it (goal evaluation
                // queries event history, not the in-flight event).
                await mocks.eventLog.storePreparedEventInHistory(event)
                await service.handleEvent(event)
            case .advanceClock(let seconds):
                // Advance the SDK clock, then let due timers fire through the
                // same public path the app lifecycle uses (foreground/init
                // call checkExpiredTimers; wall-clock timers are mocked out).
                mocks.dateProvider.advance(by: seconds)
                await service.checkExpiredTimers()
            case .assertAbsent(let names):
                // Checkpoint: none of these events may have been tracked yet.
                try await Task.sleep(nanoseconds: 100_000_000)
                let seen = Set(mocks.eventLog.trackedEvents.map(\.name))
                for name in names {
                    XCTAssertFalse(
                        seen.contains(name),
                        "[\(vector.name)] event \(name) was emitted before this timeline checkpoint allows it"
                    )
                }
            case .setExperiments(let raw):
                // Simulates a profile refetch delivering new server experiment
                // assignments mid-journey (frozen variants must not move).
                let newAssignments = try JSONDecoder().decode(
                    [String: ExperimentAssignment].self, from: raw.data
                )
                try await installProfile(experiments: newAssignments)
            }
        }

        // Let the runner's queued work settle before asserting
        try await Task.sleep(nanoseconds: 200_000_000)

        let emitted = mocks.eventLog.trackedEvents

        if let expectedSubsequence = vector.expect.ordered_event_subsequence {
            var cursor = 0
            for tracked in emitted {
                guard cursor < expectedSubsequence.count else { break }
                if tracked.name == expectedSubsequence[cursor] {
                    cursor += 1
                }
            }
            XCTAssertEqual(
                cursor, expectedSubsequence.count,
                "[\(vector.name)] expected ordered subsequence \(expectedSubsequence); got \(emitted.map(\.name))"
            )
        }

        if let forbidden = vector.expect.forbidden_events {
            let names = Set(emitted.map(\.name))
            for name in forbidden {
                XCTAssertFalse(
                    names.contains(name),
                    "[\(vector.name)] forbidden event \(name) was emitted; got \(emitted.map(\.name))"
                )
            }
        }

        if let expectedProperties = vector.expect.event_properties {
            for (eventName, expectedProps) in expectedProperties {
                guard let tracked = emitted.first(where: { $0.name == eventName }) else {
                    XCTFail("[\(vector.name)] expected event \(eventName) was not emitted")
                    continue
                }
                for (key, expected) in expectedProps {
                    let actual = tracked.properties?[key]
                    XCTAssertEqual(
                        String(describing: actual ?? "nil"),
                        String(describing: expected.value),
                        "[\(vector.name)] \(eventName).\(key)"
                    )
                }
            }
        }

        if let expectedCounts = vector.expect.event_counts {
            for (name, expectedCount) in expectedCounts {
                let actualCount = emitted.filter { $0.name == name }.count
                XCTAssertEqual(
                    actualCount, expectedCount,
                    "[\(vector.name)] expected \(name) to be tracked exactly \(expectedCount)× (got \(actualCount)); all: \(emitted.map(\.name))"
                )
            }
        }

        if let expectedActive = vector.expect.active_journeys_after {
            let active = await service.getActiveJourneys(for: distinctId)
            XCTAssertEqual(
                active.count, expectedActive,
                "[\(vector.name)] active journeys after timeline"
            )
        }

        await service.shutdown()
        await mocks.resetAll()
    }
}
