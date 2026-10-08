import CryptoKit
import Foundation
@testable import NuxieRuntime
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class JourneyReleaseTests: XCTestCase {
    private let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))

    func testPublishedF4AuthenticatesExactVersionThreePolicy() async throws {
        try await verifyPublishedF4(disagreeingRow: false)
    }

    func testSignedNonProductDefaultsCannotOverrideNativeFile() async throws {
        try await verifyPublishedF4(disagreeingRow: true)
    }

    private func verifyPublishedF4(disagreeingRow: Bool) async throws {
        let directory = PublishedRunValuesFixture.directory
        var bytes = try Data(contentsOf: directory.appendingPathComponent("release.json"))
        let entry = try JSONDecoder().decode(JourneyReleaseProfileEntry.self,
            from: Data(contentsOf: directory.appendingPathComponent("profile-entry.json")))
        if disagreeingRow {
            var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            changed["viewModelValues"] = [["viewModelName": "Experience", "instanceId": "vmi_experience",
                "instanceName": "Experience", "path": "trip_days", "value": 999]]
            bytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any])
        let timezone = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
        // Qualify these fixture bytes on the locally staged runtime without moving its release pin.
        let supported = JourneyReleaseSupportedRuntime(
            currentSdkVersion: "0.1.0",
            supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
            supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
            sceneFormat: .init(major: try XCTUnwrap(scene["major"] as? Int), minor: try XCTUnwrap(scene["minor"] as? Int)),
            timezoneDataRevision: try XCTUnwrap(timezone["revision"] as? String),
            timezoneDataSHA256: try XCTUnwrap(timezone["sha256"] as? String),
            supportedCapabilities: ["system-fonts"])
        let release = try JourneyReleaseVerifier().authenticateJourney(
            envelopeBytes: JSONEncoder().encode(disagreeingRow ? sign(bytes) : entry.envelope),
            authorizationKeys: [key(signingKey.publicKey.rawRepresentation)],
            expectedIdentity: entry.locator.identity, expectedLegId: entry.locator.legId,
            supportedRuntime: supported, replayPolicy: .active(minimumPublishedAtSeq: 0))
        XCTAssertEqual(release.exactDescriptorBytes, bytes)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("f4-release-\(UUID())")
        defer { StubURLProtocol.reset(); try? FileManager.default.removeItem(at: cache) }
        StubURLProtocol.register(matcher: { $0.url?.host == "f4.nuxie.test" }) { request in
            let url = try XCTUnwrap(request.url)
            let data = try Data(contentsOf: directory.appendingPathComponent(String(url.path.dropFirst())))
            return (try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/vnd.nuxie.scene", "Content-Length": String(data.count)])), data)
        }
        let store = JourneyReleaseAcquisitionStore(cacheDirectory: cache,
            urlSession: TestURLSessionProvider.createTestSession())
        let presentation = try await store.preparePresentation(release: release,
            delivery: .init(renderBaseUrl: "https://f4.nuxie.test/", assetBaseUrl: "https://f4.nuxie.test/"),
            productResolver: { _ in [] })
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        for declared in release.descriptor.leg.screens {
            let artifact = try await presentation.artifactLoader(presentation.experience, nil, declared.id)
            XCTAssertEqual(artifact.payload.valuePolicy.state.mapValues(\.type),
                ["trip_days": "number", "level": "number"])
            let prepared = try await ExperienceInteractivePreparation.prepare(payload: artifact.payload)
            try await prepared.prepareRunValues(run)
            let values = try await run.journeyValues()
            XCTAssertEqual(values["trip_days"], .number(23))
            XCTAssertEqual(values["level"], .number(1))
            let screen = try await prepared.openScreen(screenID: declared.id, runValues: run,
                pixelWidth: 393, pixelHeight: 852)
            _ = try await screen.step(elapsedSeconds: 0)
            try await screen.close()
        }
        XCTAssertEqual(release.descriptor.state.mapValues(\.type), ["trip_days": "number", "level": "number"])
        XCTAssertTrue(release.descriptor.responses.isEmpty)
        XCTAssertTrue(release.descriptor.ruleGroups.isEmpty)
        XCTAssertEqual(release.descriptor.leg.screens.count, 2)
        XCTAssertTrue(release.descriptor.leg.routes.contains { $0.eventName == "continue" })
    }

    func testVersionThreeRequiresValuePolicySections() throws {
        let fixture = try golden()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))) as? [String: Any])
        root["state"] = ["days": ["type": "number"], "goals": ["type": "list", "items": ["title": ["type": "string"]]]]
        root["responses"] = [String: Any]()
        root["ruleGroups"] = [Any]()
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        for key in ["state", "responses", "ruleGroups"] {
            var missing = root
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(missing), key)
        }
        root["state"] = ["days": ["type": "number", "rules": []]]
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
    }

    func testVersionThreeResponsePolicyRecordsAreStrict() throws {
        let fixture = try golden()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))) as? [String: Any])
        let rule: [String: Any] = ["model": "Responses:feedback", "property": "stars", "kind": 1,
            "mode": 0, "number_bound": 1, "text": "", "values": [], "value_count": 0,
            "picked_property": "", "bound_flags": 0, "minimum": 0, "maximum": 0,
            "code": "min", "message": "At least one"]
        let member: [String: Any] = ["property": "stars", "errors_path": "errors/stars",
            "item_model": "ResponseError", "code_property": "rule", "message_property": "message"]
        root["state"] = [String: Any]()
        root["responses"] = ["feedback": ["title": "Feedback", "model": "Responses:feedback",
            "fields": [["key": "stars", "label": "Stars", "type": "number", "rules": [rule]]]]]
        root["ruleGroups"] = [["model": "Responses:feedback", "valid": "valid", "member_count": 1, "members": [member]]]
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        var invalid = root
        invalid["ruleGroups"] = []
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(invalid))
        for (key, value) in [("mode", 1), ("value_count", 1), ("minimum", -1), ("maximum", 4_294_967_296)] {
            var wrong = rule
            wrong[key] = value
            invalid = root
            invalid["responses"] = ["feedback": ["title": "Feedback", "model": "Responses:feedback",
                "fields": [["key": "stars", "label": "Stars", "type": "number", "rules": [wrong]]]]]
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(invalid), key)
        }
    }

    func testRejectsRetiredReleaseWireVersion() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        root["schemaVersion"] = "nuxie.journey-release.v1"
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
    }

    func testVersionThreeSignatureDomainHardCut() throws {
        let fixture = try golden()
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:
            XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))) as? [String: Any])
        root["schemaVersion"] = "nuxie.journey-release.v3"
        let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let current = try sign(bytes, domain: "nuxie.journey-release.v3\u{0}")
        XCTAssertNoThrow(try authenticate(current, key: signingKey.publicKey.rawRepresentation, identity: fixture.identity))
        let retired = try sign(bytes, domain: "nuxie.journey-release.v2\u{0}")
        XCTAssertThrowsError(try authenticate(retired, key: signingKey.publicKey.rawRepresentation, identity: fixture.identity))
    }

    func testVersionThreeNativeInputHardCut() throws {
        let fixture = try golden(entryKey: "renderedEntry", file: "text-input-navigation.json")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        root["schemaVersion"] = "nuxie.journey-release.v3"
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
        let removed = ["textObjectKey", "textRunObjectKey", "textName", "textRunName", "editableValueName"]
        for index in inputs.indices {
            for field in removed { inputs[index].removeValue(forKey: field) }
            inputs[index]["textInputName"] = "Email editable value"
        }
        render["textInputs"] = inputs
        root["render"] = render
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        var retired = root
        retired["schemaVersion"] = "nuxie.journey-release.v2"
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(retired))
        for field in removed {
            var invalidInputs = inputs
            invalidInputs[0][field] = "retired"
            render["textInputs"] = invalidInputs
            root["render"] = render
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), field)
        }
        var missingInputs = inputs
        missingInputs[0].removeValue(forKey: "textInputName")
        render["textInputs"] = missingInputs
        root["render"] = render
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
        var boundedInputs = inputs
        boundedInputs[0]["textInputName"] = String(repeating: "x", count: 256)
        render["textInputs"] = boundedInputs
        root["render"] = render
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/native-input-admission.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            var candidateInputs = inputs
            candidateInputs[0]["textInputName"] = item["value"]
            render["textInputs"] = candidateInputs
            root["render"] = render
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), name)
            }
        }
    }

    func testSharedNuxOnlySceneAdmission() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/scene-admission.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            var root = source
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var scene = try XCTUnwrap(render.removeValue(forKey: "nux") as? [String: Any])
            let digest = try XCTUnwrap(scene["sha256"] as? String)
            let ext = try XCTUnwrap(item["extension"] as? String)
            scene["key"] = "renders/sha256/\(digest).\(ext)"
            scene["contentType"] = item["contentType"]
            render["renderer"] = item["renderer"]
            render[try XCTUnwrap(item["field"] as? String)] = scene
            root["render"] = render
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), name)
            }
        }
    }

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

    func testSignedBehaviorOrderingMatchesWireContract() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/behavior-ordering.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let publicKey = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["publicKeyBase64"] as? String)))
        let verifierKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        for item in try XCTUnwrap(fixture["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            let entry = try XCTUnwrap(item["entry"] as? [String: Any])
            let envelope = try JSONDecoder().decode(JourneyReleaseEnvelope.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(entry["envelope"])))
            let bytes = try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
            let signature = try XCTUnwrap(Data(base64Encoded: envelope.signature.signatureBase64))
            XCTAssertTrue(verifierKey.isValidSignature(signature, for: Data(JourneyReleaseDescriptor.signatureDomain.utf8) + bytes), name)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let identity = try JSONDecoder().decode(JourneyReleaseIdentity.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(root["identity"])))
            let leg = try XCTUnwrap(root["leg"] as? [String: Any])
            let authenticate = {
                try JourneyReleaseVerifier().authenticateJourney(envelopeBytes: JSONEncoder().encode(envelope),
                    authorizationKeys: [self.key(publicKey)], expectedIdentity: identity,
                    expectedLegId: try XCTUnwrap(leg["id"] as? String), supportedRuntime: JourneyReleaseRuntime.current,
                    replayPolicy: .active(minimumPublishedAtSeq: 0))
            }
            if item["valid"] as? Bool == true {
                XCTAssertEqual(try authenticate().exactDescriptorBytes, bytes, name)
            } else {
                XCTAssertThrowsError(try authenticate(), name) { error in
                    XCTAssertEqual(error as? JourneyReleaseAuthenticationError, .invalidDescriptor, name)
                }
            }
        }
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
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), name)
            }
        }
    }

    func testSharedNativeLineHeightAdmission() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/text-input-typography.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let golden = try golden(entryKey: "renderedEntry", file: "text-input-navigation.json")
        let bytes = try XCTUnwrap(Data(base64Encoded: golden.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for item in try XCTUnwrap(fixture["lineHeightAdmission"] as? [[String: Any]]) {
            var root = source
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
            XCTAssertFalse(inputs.isEmpty)
            var style = try XCTUnwrap(inputs[0]["style"] as? [String: Any])
            style["lineHeight"] = item["value"]
            inputs[0]["style"] = style
            render["textInputs"] = inputs
            root["render"] = render

            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), name)
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
        for (file, entryKey) in [("release.json", "renderedEntry"),
                                 ("text-input-navigation.json", "renderedEntry"),
                                 ("text-input-navigation.json", "nextBuildEntry")] {
            let fixture = try golden(entryKey: entryKey, file: file)
            let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
            let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let requirements = try XCTUnwrap(source["requirements"] as? [String: Any])
            let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
            let scene = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any])
            let timezone = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
            let supported = JourneyReleaseSupportedRuntime(
                currentSdkVersion: try XCTUnwrap(requirements["minimumSdkVersion"] as? String),
                supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
                supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
                sceneFormat: .init(major: try XCTUnwrap(scene["major"] as? Int), minor: try XCTUnwrap(scene["minor"] as? Int)),
                timezoneDataRevision: try XCTUnwrap(timezone["revision"] as? String),
                timezoneDataSHA256: try XCTUnwrap(timezone["sha256"] as? String),
                supportedCapabilities: Set(try XCTUnwrap(requirements["requiredCapabilities"] as? [String]))
            )
            let authenticated = try JourneyReleaseVerifier().authenticateJourney(
                envelopeBytes: JSONEncoder().encode(fixture.envelope), authorizationKeys: [key(fixture.publicKey)],
                expectedIdentity: fixture.identity, expectedLegId: String(repeating: "a", count: 64),
                supportedRuntime: supported, replayPolicy: .active(minimumPublishedAtSeq: 0)
            )
            XCTAssertFalse(authenticated.descriptor.leg.screens.isEmpty)
            XCTAssertNotNil(authenticated.descriptor.render)
            XCTAssertTrue(authenticated.descriptor.leg.screens.allSatisfy { $0.responseCaptures.isEmpty })
        }
    }

    func testTextInputResponseCaptureAdmission() throws {
        let fixture = try golden(entryKey: "renderedEntry", file: "text-input-navigation.json")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for (mode, secure, hasField, accepted) in [
            ("text", false, true, true), ("text", true, true, true),
            ("binding", false, true, true), ("binding", true, true, true),
            ("binding", true, false, false),
            ("binding", false, false, false), ("unknown", false, true, false),
        ] {
            var root = source
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
            XCTAssertFalse(inputs.isEmpty)
            inputs[0]["responseCapture"] = mode
            inputs[0]["secureTextEntry"] = secure
            inputs[0]["responseFieldKey"] = hasField ? "name" : nil
            render["textInputs"] = inputs
            root["render"] = render
            if accepted { XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), mode) }
            else { XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), mode) }
        }
    }

    func testTextInputActionMetadataAdmission() throws {
        let fixture = try golden(entryKey: "renderedEntry", file: "text-input-navigation.json")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let cases: [([String: Any], Bool)] = [
            ([:], true),
            (["actionEvent": "editing-ended"], true),
            (["actionEvent": "return"], true),
            (["declarativeActionId": "capture-duration"], true),
            (["actionEvent": "return", "declarativeActionId": "capture-duration"], true),
            (["textInputName": "duration-input"], true),
            (["textInputName": String(repeating: "a", count: 256)], true),
            (["textInputName": ""], false),
            (["textInputName": String(repeating: "a", count: 257)], false),
            (["textInputName": 1], false),
            (["textInputName": NSNull()], false),
            (["actionEvent": "change"], false),
            (["actionEvent": 1], false),
            (["actionEvent": NSNull()], false),
            (["declarativeActionId": ""], false),
            (["declarativeActionId": 1], false),
            (["declarativeActionId": NSNull()], false),
            (["unknownActionField": "capture-duration"], false),
        ]
        for (fields, accepted) in cases {
            var root = source
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
            XCTAssertFalse(inputs.isEmpty)
            inputs[0].removeValue(forKey: "actionEvent")
            inputs[0].removeValue(forKey: "declarativeActionId")
            inputs[0].merge(fields) { _, new in new }
            render["textInputs"] = inputs
            root["render"] = render
            if accepted {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), "\(fields)")
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), "\(fields)")
            }
        }
    }

    func testNativeEditableEndpointSurvivesSignedAcquisition() async throws {
        let fixture = try golden(entryKey: "renderedEntry", file: "text-input-navigation.json")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let scene = Data("acquisition-only-scene".utf8)
        let digest = SHA256Provider.hexDigest(scene)
        StubURLProtocol.register(matcher: { $0.url?.host == "input-acquisition.nuxie.test" }) { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Length": String(scene.count),
                "Content-Type": "application/vnd.nuxie.scene"])!, scene)
        }
        defer { StubURLProtocol.reset() }
        for secure in [false, true] {
            var root = source
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var inputs = try XCTUnwrap(render["textInputs"] as? [[String: Any]])
            inputs[0]["textInputName"] = "duration-input"
            inputs[0]["secureTextEntry"] = secure
            render["textInputs"] = inputs
            render["assets"] = []
            render["nux"] = ["contentType": "application/vnd.nuxie.scene",
                "key": "renders/sha256/\(digest).nux", "sha256": digest, "sizeBytes": scene.count]
            root["render"] = render
            let leg = try XCTUnwrap(root["leg"] as? [String: Any])
            let current = JourneyReleaseRuntime.current
            let luau = try XCTUnwrap(current.supportedLuauRevisions.first)
            root["requirements"] = [
                "minimumSdkVersion": current.currentSdkVersion,
                "runtimeRevision": try XCTUnwrap(current.supportedRuntimeRevisions.first),
                "luau": ["revision": luau.key, "bytecodeVersions": luau.value.sorted()],
                "sceneFormat": ["major": current.sceneFormat.major, "minor": current.sceneFormat.minor],
                "timezoneData": ["format": "iana-tzdb", "revision": current.timezoneDataRevision,
                    "sha256": current.timezoneDataSHA256], "requiredCapabilities": ["nux"],
            ]
            let release = try JourneyReleaseVerifier().authenticateJourney(
                envelopeBytes: JSONEncoder().encode(sign(JSONSerialization.data(withJSONObject: root))),
                authorizationKeys: [key(signingKey.publicKey.rawRepresentation)],
                expectedIdentity: fixture.identity, expectedLegId: try XCTUnwrap(leg["id"] as? String),
                supportedRuntime: current, replayPolicy: .active(minimumPublishedAtSeq: 0))
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: cache) }
            let store = JourneyReleaseAcquisitionStore(cacheDirectory: cache,
                urlSession: TestURLSessionProvider.createTestSession())
            let presentation = try await store.preparePresentation(release: release,
                delivery: .init(renderBaseUrl: "https://input-acquisition.nuxie.test/",
                    assetBaseUrl: "https://input-acquisition.nuxie.test/"), productResolver: { _ in [] })
            let screenID = try XCTUnwrap(inputs[0]["screenId"] as? String)
            let artifact = try await presentation.artifactLoader(presentation.experience, nil, screenID)
            let input = try XCTUnwrap(artifact.payload.renderPlan.textInputs.first)
            XCTAssertEqual(input.textInputName, "duration-input")
            XCTAssertEqual(input.secureTextEntry, secure)
            XCTAssertEqual(artifact.sceneBytes, scene)
        }
    }

    func testRejectsHostDismissalThatImmediatelyPresentsAgain() throws {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        leg["routes"] = [["host": ["kind": "journey"], "eventName": "host_dismissed", "entryStepId": "present"]]
        root["leg"] = leg
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
    }

    func testRejectsHostDismissalThatImmediatelyDismissesAgain() throws {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        leg["steps"] = [
            [
                "kind": "action",
                "id": "dismiss",
                "action": ["type": "dismiss"],
                "outlets": [:],
            ],
        ]
        leg["entryStepId"] = "dismiss"
        leg["routes"] = []
        root["leg"] = leg
        XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))

        leg["routes"] = [[
            "host": ["kind": "journey"],
            "eventName": "host_dismissed",
            "entryStepId": "dismiss",
        ]]
        root["leg"] = leg
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
    }

    func testAcceptsOpenLinkAfterHostDismissalAndWithoutScreens() throws {
        for entry in ["entry", "renderedEntry"] {
            let fixture = try golden(entryKey: entry)
            let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            var leg = try XCTUnwrap(root["leg"] as? [String: Any])
            leg["entryStepId"] = "link"
            leg["steps"] = [
                ["kind": "action", "id": "link", "action": ["type": "open_link", "url": ["type": "String", "value": "https://example.test"], "target": "in_app"], "outlets": ["next": "done"]],
                ["kind": "complete", "id": "done", "outcome": "continue"]
            ]
            leg["routes"] = [["host": ["kind": "journey"], "eventName": "host_dismissed", "entryStepId": "link"]]
            root["leg"] = leg
            XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root))
        }
    }

    func testRejectsPresentationActionInScreenlessLeg() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(
            Data(base64Encoded: fixture.envelope.descriptorBytesBase64)
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        leg["entryStepId"] = "dismiss"
        leg["steps"] = [
            [
                "kind": "action",
                "id": "dismiss",
                "action": ["type": "dismiss"],
                "outlets": ["next": "report"],
            ],
            [
                "kind": "complete",
                "id": "report",
                "outcome": "continue",
            ],
        ]
        root["leg"] = leg

        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
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
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
        }
    }

    func testGoalConditionsRejectMutableStateBeforeAdmission() throws {
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        var policy = try XCTUnwrap(leg["policy"] as? [String: Any])
        func goal(_ expr: [String: Any]) -> [String: Any] {
            ["criterion": ["type": "event", "eventName": "purchased", "condition": ["ir_version": 1, "expr": expr]],
             "attribution": ["basis": "entry", "window": ["amount": 1, "unit": "day"]]]
        }
        policy["goal"] = goal(["type": "Pred", "op": "eq", "key": "product_id", "value": ["type": "String", "value": "premium"]])
        leg["policy"] = policy
        root["leg"] = leg
        try JourneyReleaseSchemaValidator.validate(root)
        let mutable: [[String: Any]] = [
            ["type": "User", "op": "eq", "key": "plan", "value": ["type": "String", "value": "pro"]],
            ["type": "Feature", "op": "has", "id": "premium"],
            ["type": "Subscription", "op": "active"],
            ["type": "Segment", "op": "is_member", "id": "paid"],
            ["type": "Events.Exists", "name": "purchased"],
            ["type": "Response.Field", "key": "answer"],
        ]
        for node in mutable {
            policy["goal"] = goal(["type": "And", "args": [["type": "Bool", "value": true], node]])
            leg["policy"] = policy
            root["leg"] = leg
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), "\(node["type"] ?? "")")
        }
    }

    func testRejectsRetiredMilestoneActionsBeforeAdmission() throws {
        XCTAssertNil(JourneyActionType(rawValue: "milestone"))
        let fixture = try golden()
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try JourneyReleaseSchemaValidator.validate(root)
        var leg = try XCTUnwrap(root["leg"] as? [String: Any])
        var steps = try XCTUnwrap(leg["steps"] as? [[String: Any]])
        let originalEntry = try XCTUnwrap(leg["entryStepId"] as? String)
        steps.append(["kind": "action", "id": "evidence", "action": ["type": "send_event", "eventName": "completed"], "outlets": ["next": originalEntry]])
        leg["entryStepId"] = "evidence"
        leg["steps"] = steps
        root["leg"] = leg
        try JourneyReleaseSchemaValidator.validate(root)
        steps[steps.count - 1]["action"] = ["type": "milestone", "milestoneId": "completed"]
        leg["steps"] = steps
        root["leg"] = leg
        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
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

        XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root))
    }

    func testRejectsTamperingWrongDomainWrongLegAndReplay() throws {
        let fixture = try golden()
        var altered = fixture.envelope
        altered.descriptorBytesBase64 = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try authenticate(altered, key: fixture.publicKey, identity: fixture.identity))
        XCTAssertThrowsError(try authenticate(fixture.envelope, key: fixture.publicKey, identity: fixture.identity, legId: String(repeating: "b", count: 64)))
        XCTAssertThrowsError(
            try authenticate(
                fixture.envelope,
                key: fixture.publicKey,
                identity: fixture.identity,
                minimum: fixture.identity.publishedAtSeq + 1
            )
        )
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let wrongDomain = try sign(bytes, domain: "nuxie.invalid-signature-domain.v1\u{0}")
        XCTAssertThrowsError(try authenticate(wrongDomain, key: signingKey.publicKey.rawRepresentation, identity: fixture.identity)) { error in
            XCTAssertEqual(error as? JourneyReleaseAuthenticationError, .invalidSignature)
        }
        let pinned = try JourneyReleaseVerifier().authenticateJourney(
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
            case "server": leg["steps"] = [["kind": "action", "id": "report", "action": ["type": "connector_action", "accountRef": "account", "toolKey": "send", "payload": [:], "timeoutMs": 1_000], "outlets": [:]]]
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

    func testSharedSystemFontDeclarationCorpus() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/system-font-declarations.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let requiredConsumerCapabilities = try XCTUnwrap(corpus["consumerCapabilities"] as? [String])
        XCTAssertTrue(JourneyReleaseRuntime.current.supportedCapabilities.isSuperset(of: requiredConsumerCapabilities))
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            var root = try systemFontRoot()
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            render["assets"] = item["assets"]
            requirements["requiredCapabilities"] = item["requiredCapabilities"]
            root["render"] = render
            root["requirements"] = requirements
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root), name)
            }
        }
    }

    func testNuxVideoAdmissionContract() throws {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/video-admission.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            var root = original
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var scene = try XCTUnwrap(render.removeValue(forKey: "nux") as? [String: Any])
            let renderer = item["renderer"] as? String ?? "nux"
            let sceneField = renderer == "nux" ? "nux" : "riv"
            scene["key"] = "renders/sha256/\(try XCTUnwrap(scene["sha256"] as? String)).\(sceneField)"
            scene["contentType"] = renderer == "nux" ? "application/vnd.nuxie.scene" : "application/vnd.rive"
            render["renderer"] = renderer
            render[sceneField] = scene
            var asset = try XCTUnwrap(corpus["videoAsset"] as? [String: Any])
            asset.merge(item["assetPatch"] as? [String: Any] ?? [:]) { _, new in new }
            render["assets"] = [asset] + (item["additionalAssets"] as? [[String: Any]] ?? [])
            if let elements = item["videoElements"] { render["videoElements"] = elements }
            root["render"] = render
            if let action = item["action"] {
                var leg = try XCTUnwrap(root["leg"] as? [String: Any])
                var steps = try XCTUnwrap(leg["steps"] as? [[String: Any]])
                let index = try XCTUnwrap(steps.firstIndex { $0["kind"] as? String == "action" })
                steps[index]["action"] = action
                leg["steps"] = steps
                root["leg"] = leg
            }
            var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
            requirements["requiredCapabilities"] = item["capabilities"] ?? ["video.playback.v1"]
            root["requirements"] = requirements
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(root), name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(root), name)
            }
        }
    }

    func testSystemFontRequirementsAcceptEveryAuthoredWeightWithoutArtifactFields() throws {
        for weight in stride(from: 100, through: 900, by: 100) {
            let root = try systemFontRoot(weight: String(weight))
            XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
        }
    }

    func testSystemFontRequirementsRejectInvalidSourcesAndMissingCapability() throws {
        let invalidFields: [[String: Any]] = [
            ["key": "assets/font.ttf"], ["sha256": String(repeating: "a", count: 64)],
            ["sizeBytes": 12], ["contentType": "font/ttf"], ["format": "ttf"],
            ["family": "Roboto"], ["weight": "450"], ["style": "italic"],
            ["required": false], ["required": 1], ["location": "device"],
        ]
        for fields in invalidFields {
            var root = try systemFontRoot()
            var render = try XCTUnwrap(root["render"] as? [String: Any])
            var assets = try XCTUnwrap(render["assets"] as? [[String: Any]])
            assets[0].merge(fields) { _, replacement in replacement }
            render["assets"] = assets
            root["render"] = render
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root), "\(fields)")
        }
        var root = try systemFontRoot()
        var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
        requirements["requiredCapabilities"] = [] as [String]
        root["requirements"] = requirements
        XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
    }

    func testSystemFontDeclarationsUseUniqueSortedSemanticIdentity() throws {
        var root = try systemFontRoot()
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        let first = try XCTUnwrap((render["assets"] as? [[String: Any]])?.first)
        var second = first
        second["assetUniqueName"] = "system-700-2"
        second["authoredAssetId"] = 2
        second["weight"] = "700"
        render["assets"] = [first, second]
        root["render"] = render
        XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
        for assets in [[second, first], [first, first]] {
            render["assets"] = assets
            root["render"] = render
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
        }
    }

    func testCDNFontRequiresSourceAndCannotMasqueradeAsSystem() throws {
        var root = try systemFontRoot()
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        let digest = String(repeating: "a", count: 64)
        let font: [String: Any] = [
            "kind": "font", "location": "cdn", "family": "Roboto", "weight": "400",
            "style": "normal", "required": true, "authoredAssetId": 1, "assetUniqueName": "roboto-1",
            "key": "assets/sha256/\(digest).ttf", "sha256": digest, "sizeBytes": 100,
            "contentType": "font/ttf", "format": "ttf",
        ]
        render["assets"] = [font]
        root["render"] = render
        XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
        for family in ["System", " system ", "SYSTEM"] {
            var invalid = font
            invalid["family"] = family
            render["assets"] = [invalid]
            root["render"] = render
            XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
        }
        var missingSource = font
        missingSource.removeValue(forKey: "location")
        render["assets"] = [missingSource]
        root["render"] = render
        XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateRenderRequirements(root))
    }

    func testSignedSystemFontRequiresConsumerCapability() throws {
        let root = try systemFontRoot()
        let envelope = try sign(JSONSerialization.data(withJSONObject: root))
        let fixture = try golden(entryKey: "renderedEntry")
        let requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(requirements["sceneFormat"] as? [String: Any])
        let timezone = try XCTUnwrap(requirements["timezoneData"] as? [String: Any])
        for supportsSystem in [false, true] {
            let supported = JourneyReleaseSupportedRuntime(
                currentSdkVersion: try XCTUnwrap(requirements["minimumSdkVersion"] as? String),
                supportedRuntimeRevisions: [try XCTUnwrap(requirements["runtimeRevision"] as? String)],
                supportedLuauRevisions: [try XCTUnwrap(luau["revision"] as? String): Set(try XCTUnwrap(luau["bytecodeVersions"] as? [Int]))],
                sceneFormat: .init(major: try XCTUnwrap(scene["major"] as? Int), minor: try XCTUnwrap(scene["minor"] as? Int)),
                timezoneDataRevision: try XCTUnwrap(timezone["revision"] as? String),
                timezoneDataSHA256: try XCTUnwrap(timezone["sha256"] as? String),
                supportedCapabilities: supportsSystem ? ["system-fonts"] : []
            )
            let authenticate = {
                try JourneyReleaseVerifier().authenticateJourney(
                    envelopeBytes: JSONEncoder().encode(envelope), authorizationKeys: [self.key(self.signingKey.publicKey.rawRepresentation)],
                    expectedIdentity: fixture.identity, expectedLegId: String(repeating: "a", count: 64),
                    supportedRuntime: supported, replayPolicy: .active(minimumPublishedAtSeq: 0)
                )
            }
            if supportsSystem {
                XCTAssertNoThrow(try authenticate())
            } else {
                XCTAssertThrowsError(try authenticate()) { error in
                    XCTAssertEqual(error as? JourneyReleaseAuthenticationError, .unsupportedCapabilities(["system-fonts"]))
                }
            }
        }
    }

    func testSharedVideoActionContract() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/video-actions.json")
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        for item in try XCTUnwrap(corpus["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            if item["valid"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateCanonicalJourneyAction(
                    item["action"], path: "action", screenIDs: [], placementIDs: []), name)
                let bytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["action"]))
                let action = try JSONDecoder().decode([String: JourneyReleaseJSONValue].self, from: bytes)
                let command = try JourneyVideoAction(action: action)
                XCTAssertEqual(command.commandKind, (item["kind"] as? NSNumber)?.uint32Value, name)
                XCTAssertEqual(command.commandValue, (item["value"] as? NSNumber)?.doubleValue, name)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateCanonicalJourneyAction(
                    item["action"], path: "action", screenIDs: [], placementIDs: []), name)
            }
        }
    }

    func testCurrentSDKAuthenticatesSignedSystemFontRelease() throws {
        let current = JourneyReleaseRuntime.current
        var root = try systemFontRoot()
        let luau = try XCTUnwrap(current.supportedLuauRevisions.first)
        root["requirements"] = [
            "minimumSdkVersion": current.currentSdkVersion,
            "runtimeRevision": try XCTUnwrap(current.supportedRuntimeRevisions.first),
            "luau": ["revision": luau.key, "bytecodeVersions": luau.value.sorted()],
            "sceneFormat": ["major": current.sceneFormat.major, "minor": current.sceneFormat.minor],
            "timezoneData": ["format": "iana-tzdb", "revision": current.timezoneDataRevision, "sha256": current.timezoneDataSHA256],
            "requiredCapabilities": ["system-fonts"],
        ]
        let envelope = try sign(JSONSerialization.data(withJSONObject: root))
        let fixture = try golden(entryKey: "renderedEntry")
        XCTAssertNoThrow(try JourneyReleaseVerifier().authenticateJourney(
            envelopeBytes: JSONEncoder().encode(envelope),
            authorizationKeys: [key(signingKey.publicKey.rawRepresentation)],
            expectedIdentity: fixture.identity, expectedLegId: String(repeating: "a", count: 64),
            supportedRuntime: current, replayPolicy: .active(minimumPublishedAtSeq: 0)
        ))
    }

    private func systemFontRoot(weight: String = "400") throws -> [String: Any] {
        let fixture = try golden(entryKey: "renderedEntry")
        let bytes = try XCTUnwrap(Data(base64Encoded: fixture.envelope.descriptorBytesBase64))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var render = try XCTUnwrap(root["render"] as? [String: Any])
        render["assets"] = [[
            "kind": "font", "location": "system", "family": "System",
            "weight": weight, "style": "normal", "required": true,
            "authoredAssetId": 1, "assetUniqueName": "system-400-1",
        ]]
        root["render"] = render
        var requirements = try XCTUnwrap(root["requirements"] as? [String: Any])
        requirements["requiredCapabilities"] = ["system-fonts"]
        root["requirements"] = requirements
        return root
    }

    private func authenticate(_ envelope: JourneyReleaseEnvelope, key publicKey: Data,
                              identity: JourneyReleaseIdentity, legId: String = String(repeating: "a", count: 64), minimum: Int = 0) throws -> AuthenticatedJourneyRelease {
        try JourneyReleaseVerifier().authenticateJourney(
            envelopeBytes: JSONEncoder().encode(envelope), authorizationKeys: [key(publicKey)],
            expectedIdentity: identity, expectedLegId: legId, supportedRuntime: runtime,
            replayPolicy: .active(minimumPublishedAtSeq: minimum)
        )
    }

    private func key(_ bytes: Data) -> JourneyPackageAuthorizationKey {
        JourneyPackageAuthorizationKey(keyID: "TEST_ONLY_DEV_KEYPAIR", ed25519PublicKeyBytes: bytes)
    }

    private var runtime: JourneyReleaseSupportedRuntime {
        .init(currentSdkVersion: "0.1.0", supportedRuntimeRevisions: [], supportedLuauRevisions: [:],
              sceneFormat: .init(major: 1, minor: 0), timezoneDataRevision: "unused", timezoneDataSHA256: "unused", supportedCapabilities: [])
    }

    private func sign(_ bytes: Data, domain: String = JourneyReleaseDescriptor.signatureDomain) throws -> JourneyReleaseEnvelope {
        .init(mediaType: JourneyReleaseDescriptor.mediaType, encoding: "base64", descriptorSha256: SHA256Provider.hexDigest(bytes),
              descriptorSizeBytes: bytes.count, descriptorBytesBase64: bytes.base64EncodedString(),
              signature: .init(version: 1, algorithm: "ed25519", keyId: "TEST_ONLY_DEV_KEYPAIR",
                  signatureBase64: try signingKey.signature(for: Data(domain.utf8) + bytes).base64EncodedString()))
    }

    private func golden(entryKey: String = "entry", file: String = "release.json") throws -> (envelope: JourneyReleaseEnvelope, identity: JourneyReleaseIdentity, publicKey: Data) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/\(file)")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let entry = try XCTUnwrap(fixture[entryKey] as? [String: Any])
        let envelope = try JSONDecoder().decode(JourneyReleaseEnvelope.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(entry["envelope"])))
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))) as? [String: Any])
        return (envelope, try JSONDecoder().decode(JourneyReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(descriptor["identity"]))),
                try XCTUnwrap(Data(base64Encoded: XCTUnwrap(fixture["publicKeyBase64"] as? String))))
    }
}
