import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyPlaneProfileTests: XCTestCase {
    func testOrdinalFactNamesRemainDistinctAtEntryEvaluation() async throws {
        var root = try fixture()
        root["facts"] = try JSONSerialization.jsonObject(with: Data(#"{"properties":{"é":{"present":true,"value":false},"e\u0301":{"present":true,"value":true}},"memberships":{"é":false,"e\u0301":true},"assignments":{"é":{"variantId":"one","isHoldout":false},"e\u0301":{"variantId":"two","isHoldout":true}}}"#.utf8))
        let profile = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(profile.facts.properties.count, 2)
        XCTAssertEqual(profile.facts.properties["é"]?.value?.value as? Bool, false)
        XCTAssertEqual(profile.facts.properties["e\u{0301}"]?.value?.value as? Bool, true)
        XCTAssertEqual(profile.facts.assignments["é"]??.variantId, "one")
        XCTAssertEqual(profile.facts.assignments["e\u{0301}"]??.variantId, "two")
        for (key, expected) in [("é", false), ("e\u{0301}", true)] {
            let matches = await DeviceLegEntryEvaluator.matches(
                .init(type: .segment, eventName: nil, segmentId: key, member: true, condition: nil),
                facts: profile.facts, references: .init(propertyKeys: [], segmentIds: [key], experimentIds: []),
                foreground: true, event: nil, now: Date())
            XCTAssertEqual(matches, expected)
        }
    }

    func testDecodesFlatFactsAndExactContinuationWithoutLegacyProtocol() throws {
        let profile = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: fixture()))
        XCTAssertEqual(profile.armedLegs.first?.binding.generation, 7)
        XCTAssertEqual(profile.armedLegs.first?.binding.type, .continuation)
        XCTAssertEqual(profile.facts.memberships["opaque"], false)
        XCTAssertEqual(profile.facts.properties["missing"]?.present, false)
        XCTAssertEqual(profile.facts.properties["null"]?.present, true)
        XCTAssertTrue(profile.facts.assignments.keys.contains("unfetched"))
        XCTAssertEqual(profile.releases.count, 1)
    }

    func testRejectsUnknownFieldsMissingReleaseDuplicatesAndInvalidGeneration() throws {
        for variant in ["legacy", "missing", "duplicate", "unreferenced", "mismatch", "binding", "generation", "fraction", "uuid", "presence", "membership"] {
            var root = try fixture()
            var arms = try XCTUnwrap(root["armedLegs"] as? [[String: Any]])
            var arm = try XCTUnwrap(arms.first)
            switch variant {
            case "legacy": root["mailbox"] = []
            case "missing": root["releases"] = []
            case "duplicate": arms.append(arm)
            case "unreferenced": arms = []
            case "mismatch":
                var reference = try XCTUnwrap(arm["reference"] as? [String: Any])
                reference["legId"] = String(repeating: "b", count: 64)
                arm["reference"] = reference; arms[0] = arm
            case "binding", "generation", "fraction", "uuid":
                var binding = try XCTUnwrap(arm["binding"] as? [String: Any])
                if variant == "binding" { binding["epoch"] = 1 }
                if variant == "generation" { binding["generation"] = true }
                if variant == "fraction" { binding["generation"] = 1.5 }
                if variant == "uuid" { binding["journeyId"] = "00000000-0000-4000-8000-000000000001" }
                arm["binding"] = binding; arms[0] = arm
            default:
                var facts = try XCTUnwrap(root["facts"] as? [String: Any])
                if variant == "presence" { facts["properties"] = ["broken": ["present": false, "value": "hidden"]] }
                if variant == "membership" { facts["memberships"] = ["opaque": 0] }
                root["facts"] = facts
            }
            root["armedLegs"] = arms
            XCTAssertThrowsError(try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: root)), variant)
        }
    }

    func testRejectsInvalidReleaseValuesBeforeReplacingDelivery() throws {
        for variant in ["version", "sequence", "environment", "releaseCreatedAt", "algorithm", "size", "base64"] {
            var root = try fixture()
            var entries = try XCTUnwrap(root["releases"] as? [[String: Any]])
            var entry = entries[0]
            var locator = try XCTUnwrap(entry["locator"] as? [String: Any])
            var envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
            switch variant {
            case "version": locator["versionNumber"] = 0
            case "sequence": locator["releaseSequence"] = -1
            case "environment": locator["environment"] = "unknown"
            case "releaseCreatedAt": locator["releaseCreatedAt"] = "2026-02-31T00:00:00Z"
            case "size": envelope["descriptorSizeBytes"] = -1
            case "base64": envelope["descriptorBytesBase64"] = "???"
            default:
                var signature = try XCTUnwrap(envelope["signature"] as? [String: Any])
                signature["algorithm"] = "rsa"; envelope["signature"] = signature
            }
            entry["locator"] = locator; entry["envelope"] = envelope; entries[0] = entry; root["releases"] = entries
            XCTAssertThrowsError(try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: root)), variant)
        }
    }

    func testRequiresCredentialFreeHttpsDeliveryDirectories() throws {
        for url in ["http://example.com/", "https://user:secret@example.com/", "https://example.com/base", "https://example.com/?query=1", "https://example.com/#fragment"] {
            var root = try fixture()
            root["delivery"] = ["renderBaseUrl": "https://example.com/", "assetBaseUrl": url]
            XCTAssertThrowsError(try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: root)), url)
        }
    }

    func testAllowsCurrentFactsForCachedRunsWithoutRearming() throws {
        var root = try fixture()
        root["armedLegs"] = []; root["releases"] = []
        let profile = try JourneyPlaneProfile.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(profile.facts.memberships["opaque"], false)
        XCTAssertTrue(profile.armedLegs.isEmpty)
    }

    private func fixture() throws -> [String: Any] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/release.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let entry = try XCTUnwrap(fixture["entry"] as? [String: Any])
        let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        return [
            "schemaVersion": "nuxie.journey-plane-profile.v1", "status": "ok",
            "delivery": ["renderBaseUrl": "https://renders.example.com", "assetBaseUrl": "https://assets.example.com"],
            "features": [], "facts": ["properties": ["missing": ["present": false], "null": ["present": true, "value": NSNull()]],
                "memberships": ["opaque": false], "assignments": ["unfetched": NSNull()]],
            "releases": [entry], "armedLegs": [[
                "reference": ["experienceId": locator["experienceId"]!, "versionId": locator["experienceVersionId"]!,
                    "legId": locator["legId"]!, "descriptorSha256": envelope["descriptorSha256"]!],
                "binding": ["type": "continue", "journeyId": "00000000-0000-7000-8000-000000000001", "generation": 7],
                "entryCondition": ["type": "app_foregrounded"], "context": ["event": [:], "responses": [:]],
            ]],
        ]
    }
}
