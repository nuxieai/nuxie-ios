import CryptoKit
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class DeviceLegReleaseTests: XCTestCase {
    private let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))

    func testAuthenticatesBothOrdinalOutputDeclarations() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        let fields: [[String: Any]] = [
            ["key": "é", "type": "boolean", "required": false],
            ["key": "e\u{0301}", "type": "boolean", "required": false],
        ]
        leg["outputs"] = fields
        leg["completionOutputs"] = ["continue": ["eventFields": [], "responseFields": fields]]
        root["leg"] = leg
        let release = try authenticate(sign(JSONSerialization.data(withJSONObject: root)),
                                       key: signingKey.publicKey.rawRepresentation, identity: fixture.identity)
        XCTAssertEqual(release.descriptor.leg.outputs.count, 2)
        XCTAssertEqual(release.descriptor.leg.completionOutputs["continue"]?.responseFields.count, 2)
    }

    func testSharedAdmissionCases() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/admission.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        for item in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) {
            let golden = try golden(entryKey: XCTUnwrap(item["entry"] as? String))
            let bytes = try XCTUnwrap(Data(base64Encoded: golden.envelope.descriptorBytesBase64))
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var leg = try XCTUnwrap(root["leg"] as? [String: Any])
            leg.merge(try XCTUnwrap(item["leg"] as? [String: Any])) { _, new in new }
            root["leg"] = leg
            root.merge(try XCTUnwrap(item["descriptor"] as? [String: Any])) { _, new in new }
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try DeviceLegSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try DeviceLegSchemaValidator.validate(root), name)
            }
        }
    }

    func testAuthenticatesPublisherGoldenBytesWithoutRenderOrChain() throws {
        let fixture = try golden()
        let release = try authenticate(fixture.envelope, key: fixture.publicKey, identity: fixture.identity)
        XCTAssertEqual(release.exactDescriptorBytes, Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        XCTAssertEqual(release.descriptor.leg.id, String(repeating: "a", count: 64))
        XCTAssertEqual(release.descriptor.leg.steps.first?.outcome, "continue")
        XCTAssertNil(release.descriptor.render)
        XCTAssertEqual(release.publishedAtSeqToPromote, fixture.identity.publishedAtSeq)
    }

    func testAuthenticatesRenderedLegWithExactScreenClosure() throws {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let requirements = try XCTUnwrap(source["requirements"] as? [String: Any])
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any])
        let timezone = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
        let supported = ExperienceReleaseSupportedRuntime(
            currentSdkVersion: try XCTUnwrap(requirements["minimumSdkVersion"] as? String),
            supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
            supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
            sceneFormat: .init(major: try XCTUnwrap(scene["major"] as? Int), minor: try XCTUnwrap(scene["minor"] as? Int)),
            timezoneDataRevision: try XCTUnwrap(timezone["revision"] as? String),
            timezoneDataSHA256: try XCTUnwrap(timezone["sha256"] as? String),
            supportedCapabilities: Set(try XCTUnwrap(requirements["requiredCapabilities"] as? [String]))
        )
        let authenticated = try ExperienceReleaseDescriptorVerifier().authenticateDeviceLeg(
            envelopeBytes: JSONEncoder().encode(fixture.envelope), authorizationKeys: [key(fixture.publicKey)],
            expectedIdentity: fixture.identity, expectedLegId: String(repeating: "a", count: 64),
            supportedRuntime: supported, replayPolicy: .active(minimumPublishedAtSeq: 0)
        )
        XCTAssertFalse(authenticated.descriptor.leg.screens.isEmpty)
        XCTAssertNotNil(authenticated.descriptor.render)
        XCTAssertTrue(authenticated.descriptor.leg.screens.allSatisfy { $0.responseCaptures.isEmpty })
    }

    func testRejectsHostDismissalThatImmediatelyPresentsAgain() throws {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNoThrow(try DeviceLegSchemaValidator.validate(root))
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        leg["routes"] = [["host": ["kind": "journey"], "eventName": "host_dismissed", "entryStepId": "present"]]
        root["leg"] = leg
        XCTAssertThrowsError(try DeviceLegSchemaValidator.validate(root))
    }

    func testValidatesWaitPayloadSchemaBeforeAdmission() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        let condition: [String: Any] = ["type": "Truthy", "value": ["type": "Boolean", "value": true]]
        for payload in [["garbage": true], ["type": "object", "fields": [["key": "x", "type": "future", "required": true]], "additionalProperties": false]] as [[String: Any]] {
            leg["steps"] = [["kind": "action", "id": "report", "action": ["type": "wait_until", "trigger": ["kind": "event", "eventName": "paid", "payloadSchema": payload], "condition": condition, "maxTimeMs": 1000], "outlets": [:]]]
            root["leg"] = leg
            XCTAssertThrowsError(try DeviceLegSchemaValidator.validate(root))
        }
    }

    func testRejectsReservedAuthoredEventNamesBeforeAdmission() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(
            Data(base64Encoded: fixture.envelope.descriptorBytesBase64)
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        leg["entryStepId"] = "send"
        leg["steps"] = [
            [
                "kind": "action",
                "id": "send",
                "action": [
                    "type": "send_event",
                    "eventName": "$journey_milestone",
                ],
                "outlets": ["next": "report"],
            ],
            [
                "kind": "complete",
                "id": "report",
                "outcome": "continue",
            ],
        ]
        root["leg"] = leg

        XCTAssertThrowsError(try DeviceLegSchemaValidator.validate(root))
    }

    func testRejectsTamperingWrongDomainWrongLegAndReplay() throws {
        let fixture = try golden()
        var altered = fixture.envelope
        altered.descriptorBytesBase64 = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try authenticate(altered, key: fixture.publicKey, identity: fixture.identity))
        XCTAssertThrowsError(try authenticate(fixture.envelope, key: fixture.publicKey, identity: fixture.identity, legId: String(repeating: "b", count: 64)))
        XCTAssertThrowsError(try authenticate(fixture.envelope, key: fixture.publicKey, identity: fixture.identity, minimum: fixture.identity.publishedAtSeq + 1))
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let wrongDomain = try sign(bytes, domain: ExperienceReleaseDescriptorLimits.signatureDomain)
        XCTAssertThrowsError(try authenticate(wrongDomain, key: signingKey.publicKey.rawRepresentation, identity: fixture.identity)) { error in
            XCTAssertEqual(error as? ExperienceReleaseDescriptorAuthenticationError, .invalidSignature)
        }
        let pinned = try ExperienceReleaseDescriptorVerifier().authenticateDeviceLeg(
            envelopeBytes: JSONEncoder().encode(fixture.envelope), authorizationKeys: [key(fixture.publicKey)],
            expectedIdentity: fixture.identity, expectedLegId: String(repeating: "a", count: 64),
            supportedRuntime: runtime, replayPolicy: .pinned(experienceVersionId: fixture.identity.experienceVersionId,
                buildId: fixture.identity.buildId, descriptorSHA256: fixture.envelope.descriptorSha256)
        )
        XCTAssertNil(pinned.publishedAtSeqToPromote)
    }

    func testRejectsAuthenticatedCrossLegCursorsServerActionsAndChainFields() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for variant in ["cursor", "server", "chain", "fact", "schema", "duplicate", "render"] {
            var root = source
            var leg = try XCTUnwrap(root["leg"] as? [String: Any])
            switch variant {
            case "cursor": leg["steps"] = [["kind": "action", "id": "report", "action": ["type": "send_event", "eventName": "hello"], "outlets": ["next": "another-leg"]]]
            case "server": leg["steps"] = [["kind": "action", "id": "report", "action": ["type": "grant_entitlement", "featureId": "paid", "unlimited": true], "outlets": [:]]]
            case "chain": root["serverLegs"] = []
            case "fact": leg["entryCondition"] = ["type": "segment", "segmentId": "opaque", "member": false]
            case "schema": leg["schemaVersion"] = "future"
            case "duplicate": leg["steps"] = [["kind": "complete", "id": "report", "outcome": "continue"], ["kind": "complete", "id": "report", "outcome": "continue"]]
            default: leg["screens"] = [["id": "screen", "responseCaptures": []]]
            }
            root["leg"] = leg
            let envelope = try sign(JSONSerialization.data(withJSONObject: root))
            XCTAssertThrowsError(try authenticate(envelope, key: signingKey.publicKey.rawRepresentation, identity: fixture.identity), variant)
        }
    }

    private func authenticate(_ envelope: ExperienceReleaseDescriptorEnvelope, key publicKey: Data,
                              identity: ExperienceReleaseIdentity, legId: String = String(repeating: "a", count: 64), minimum: Int = 0) throws -> AuthenticatedDeviceLegRelease {
        try ExperienceReleaseDescriptorVerifier().authenticateDeviceLeg(
            envelopeBytes: JSONEncoder().encode(envelope), authorizationKeys: [key(publicKey)],
            expectedIdentity: identity, expectedLegId: legId, supportedRuntime: runtime,
            replayPolicy: .active(minimumPublishedAtSeq: minimum)
        )
    }

    private func key(_ bytes: Data) -> ExperiencePackageAuthorizationKey {
        ExperiencePackageAuthorizationKey(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: bytes)
    }

    private var runtime: ExperienceReleaseSupportedRuntime {
        .init(currentSdkVersion: "0.1.0", supportedRuntimeRevisions: [], supportedLuauRevisions: [:],
              sceneFormat: .init(major: 1, minor: 0), timezoneDataRevision: "unused", timezoneDataSHA256: "unused", supportedCapabilities: [])
    }

    private func sign(_ bytes: Data, domain: String = DeviceLegReleaseDescriptor.signatureDomain) throws -> ExperienceReleaseDescriptorEnvelope {
        .init(mediaType: DeviceLegReleaseDescriptor.mediaType, encoding: "base64", descriptorSha256: SHA256Provider.hexDigest(bytes),
              descriptorSizeBytes: bytes.count, descriptorBytesBase64: bytes.base64EncodedString(),
              signature: .init(version: 1, algorithm: "ed25519", keyId: "TEST_ONLY_DEV_KEYPAIR",
                  signatureBase64: try signingKey.signature(for: Data(domain.utf8) + bytes).base64EncodedString()))
    }

    private func golden(entryKey: String = "entry") throws -> (envelope: ExperienceReleaseDescriptorEnvelope, identity: ExperienceReleaseIdentity, publicKey: Data) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/release.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let entry = try XCTUnwrap(fixture[entryKey] as? [String: Any])
        let envelope = try JSONDecoder().decode(ExperienceReleaseDescriptorEnvelope.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(entry["envelope"])))
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))) as? [String: Any])
        return (envelope, try JSONDecoder().decode(ExperienceReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(descriptor["identity"]))),
                try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["publicKeyBase64"] as? String))))
    }
}
