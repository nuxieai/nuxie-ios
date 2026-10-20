#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceValuePolicyTests: XCTestCase {
    func testGroupInstallationKeepsUnconstrainedAnswers() async throws {
        try await checkUnconstrainedGroup(requiredEmail: true)
    }

    func testGroupInstallationRetainsAnEmptyNativeGroup() async throws {
        try await checkUnconstrainedGroup(requiredEmail: false)
    }

    private func checkUnconstrainedGroup(requiredEmail: Bool) async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("rule-group-install")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("policy.json"))) as? [String: Any])
        if !requiredEmail {
            var forms = try XCTUnwrap(root["responses"] as? [String: Any])
            var form = try XCTUnwrap(forms["profile"] as? [String: Any])
            var fields = try XCTUnwrap(form["fields"] as? [[String: Any]])
            fields[0]["rules"] = []
            form["fields"] = fields; forms["profile"] = form; root["responses"] = forms
        }
        try JourneyReleaseValuePolicy.validate(root)
        let policy = try JSONDecoder().decode(JourneyReleaseValuePolicy.self,
            from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(policy.ruleGroups.first?.members.map(\.property), ["email", "name"],
            "The canonical group still lists every declared field")
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: policy.native)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let prepared = try await run.native(in: file)
        let native = try XCTUnwrap(prepared)
        func member(_ snapshot: NuxieNativeViewModelSnapshot, _ path: [String]) throws -> NuxieNativeViewModelValue? {
            var owner = snapshot.rootInstanceID
            for name in path.dropLast() {
                guard case .referencedInstance(let next) = snapshot.values.first(where: {
                    $0.ownerInstanceID == owner && $0.name == name
                })?.value else { throw CocoaError(.coderInvalidValue) }
                owner = next
            }
            return snapshot.values.first { $0.ownerInstanceID == owner && $0.name == path.last }?.value
        }
        _ = try await native.sessions.mutate([
            .setString(instance: native.reference, path: "responses:profile/email", value: Data("person@example.test".utf8)),
            .setString(instance: native.reference, path: "responses:profile/name", value: Data("Ada".utf8)),
        ])
        let valid = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(try member(valid, ["responses:profile", "valid"]), .bool(true))
        XCTAssertEqual(try member(valid, ["responses:profile", "errors", "name"]), .list([]))
        let request = try XCTUnwrap(ExperienceResponseSaveRequest.capture(
            .hostCommand(name: "$nuxie.response.save", payload: .object([.init(key: "form", value: .string("profile"))])),
            snapshot: valid, catalog: native.catalog, policy: policy))
        XCTAssertEqual(request.answers, ["email": .string("person@example.test"), "name": .string("Ada")])
        let answers = try await run.responseAnswers(form: "profile", policy: policy)
        XCTAssertEqual(answers, request.answers)
        _ = try await native.sessions.mutate([
            .setString(instance: native.reference, path: "responses:profile/email", value: Data()),
        ])
        let cleared = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(try member(cleared, ["responses:profile", "valid"]), .bool(!requiredEmail))
        XCTAssertEqual(try member(cleared, ["responses:profile", "errors", "name"]), .list([]))
    }

    func testNestedObjectDeclarationsKeepStrictShapes() throws {
        let state = try JSONSerialization.jsonObject(with: Data(#"{"profile":{"type":"object","fields":{"name":{"type":"string"},"minutes":{"type":"number"},"topics":{"type":"enum","values":["Reading, writing","Travel"],"multiple":true},"settings":{"type":"object","fields":{"day":{"type":"date"}}}}}}"#.utf8))
        func validate(_ value: Any) throws {
            try JourneyReleaseValuePolicy.validate(["state": value, "responses": [:], "ruleGroups": []])
        }
        XCTAssertNoThrow(try validate(state))
        let invalid = [
            #"{"profile":{"type":"object"}}"#,
            #"{"profile":{"type":"object","fields":{}}}"#,
            #"{"profile":{"type":"list","items":{"x":{"type":"number"}},"fields":{"x":{"type":"number"}}}}"#,
            #"{"profile":{"type":"object","items":{"x":{"type":"number"}},"fields":{"x":{"type":"number"}}}}"#,
            #"{"profile":{"type":"number","fields":{"x":{"type":"number"}}}}"#,
            #"{"profile":{"type":"object","fields":{"name":{"type":"string","extra":true}}}}"#,
            #"{"profile":{"type":"object","fields":{"name":{"type":"string","default":"Ana"}}}}"#,
            #"{"profile":{"type":"object","fields":{"isset:name":{"type":"boolean"}}}}"#,
            #"{"profile":{"type":"object","fields":{"x":{"type":"enum","values":["a","a"]}}}}"#,
            #"{"profile":{"type":"object","fields":{"x":{"type":"number","multiple":true}}}}"#,
            #"{"profile":{"type":"object","fields":{"x":{"type":"list"}}}}"#,
            #"{"profile":{"type":"object","fields":{"x":{"type":"date","fields":{}}}}}"#,
        ]
        for text in invalid {
            XCTAssertThrowsError(try validate(JSONSerialization.jsonObject(with: Data(text.utf8))), text) {
                XCTAssertEqual($0 as? JourneyReleaseAuthenticationError, .invalidDescriptor)
            }
        }
        XCTAssertThrowsError(try JourneyReleaseValuePolicy.validate([
            "state": [:], "responses": ["form": ["title": "Form", "model": "Responses:form",
                "fields": [["key": "profile", "label": "Profile", "type": "object", "fields": ["x": ["type": "number"]], "rules": []]]]], "ruleGroups": []
        ]))
    }

    func testPublishedF5InstallsResponseRulesBeforeFirstMutation() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("release.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        try JourneyReleaseSchemaValidator.validate(root)
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self, from: bytes)
        XCTAssertEqual(Set(release.responses.keys), ["onboarding", "feedback"])
        XCTAssertEqual(release.ruleGroups.count, 2)
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: release.valuePolicy.native)
        for _ in 0..<2 {
            let run = ExperienceRunValues()
            addTeardownBlock { await run.retire() }
            let result = try await run.native(in: file)
            let native = try XCTUnwrap(result)
            func feedback(_ snapshot: NuxieNativeViewModelSnapshot, _ field: String) throws -> NuxieNativeViewModelValue? {
                guard case .referencedInstance(let id) = snapshot.values.first(where: {
                    $0.ownerInstanceID == native.reference.rawValue && $0.name == "responses:feedback"
                })?.value else { throw CocoaError(.coderInvalidValue) }
                return snapshot.values.first { $0.ownerInstanceID == id && $0.name == field }?.value
            }
            let initial = try await native.sessions.snapshot(native.reference)
            XCTAssertEqual(try feedback(initial, "stars"), .number(0))
            XCTAssertEqual(try feedback(initial, "isset:stars"), .bool(false))
            XCTAssertEqual(try feedback(initial, "valid"), .bool(false))
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "responses:feedback/stars", value: 4)])
            let accepted = try await native.sessions.snapshot(native.reference)
            XCTAssertEqual(try feedback(accepted, "stars"), .number(4))
            XCTAssertEqual(try feedback(accepted, "isset:stars"), .bool(true))
            XCTAssertEqual(try feedback(accepted, "valid"), .bool(true), "Unanswered optional interests do not fail minItems")
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "responses:feedback/stars", value: 6)])
            let refused = try await native.sessions.snapshot(native.reference)
            XCTAssertEqual(try feedback(refused, "stars"), .number(4))
        }
    }

    func testPublishedF5SaveDisplayKeepsNewestAttempt() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("release.json")))
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: release.valuePolicy.native)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let prepared = try await run.native(in: file)
        let native = try XCTUnwrap(prepared)
        let failure = JourneyResponseSaveDisplay(sequence: 2, saving: false, saved: false, saveError: "save_unavailable")
        try await run.applyResponseSaveDisplays(["feedback": .saving(sequence: 1)], policy: release.valuePolicy)
        try await run.applyResponseSaveDisplays(["feedback": failure], policy: release.valuePolicy)
        try await run.applyResponseSaveDisplays(["feedback": .init(sequence: 1, saving: false, saved: true, saveError: "")], policy: release.valuePolicy)
        try await run.applyResponseSaveDisplays(["feedback": .saving(sequence: 2)], policy: release.valuePolicy)
        func status() async throws -> [String: NuxieNativeViewModelValue] {
            let snapshot = try await native.sessions.snapshot(native.reference)
            guard case .referencedInstance(let id) = snapshot.values.first(where: {
                $0.ownerInstanceID == native.reference.rawValue && $0.name == "responses:feedback"
            })?.value else { throw CocoaError(.coderInvalidValue) }
            return Dictionary(uniqueKeysWithValues: snapshot.values.filter {
                $0.ownerInstanceID == id && ["saving", "saved", "saveError"].contains($0.name)
            }.map { ($0.name, $0.value) })
        }
        let failed = try await status()
        XCTAssertEqual(failed, ["saving": .bool(false), "saved": .bool(false), "saveError": .bytes(Data("save_unavailable".utf8))])
        try await run.applyResponseSaveDisplays(["feedback": .saving(sequence: 3)], policy: release.valuePolicy)
        let pending = try await status()
        XCTAssertEqual(pending, ["saving": .bool(true), "saved": .bool(false), "saveError": .bytes(Data())])
        try await run.applyResponseSaveDisplays(["feedback": .init(sequence: 3, saving: false, saved: true, saveError: "")], policy: release.valuePolicy)
        let saved = try await status()
        XCTAssertEqual(saved, ["saving": .bool(false), "saved": .bool(true), "saveError": .bytes(Data())])
    }

    func testSaveEventCapturesItsCommittedNativeSheet() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("release.json")))
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: release.valuePolicy.native)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let prepared = try await run.native(in: file)
        let native = try XCTUnwrap(prepared)
        _ = try await native.sessions.mutate([
            .setNumber(instance: native.reference, path: "responses:feedback/stars", value: 4),
        ])
        let snapshot = try await native.sessions.snapshot(native.reference)
        let fields: [ExperienceInteractiveField] = [
            .init(key: "form", value: .bytes(Data("feedback".utf8))),
            .init(key: "awaitTrigger", value: .bytes(Data("state/save:one:click:0".utf8))),
        ]
        let event = ExperienceInteractiveReportedEvent(localIndex: 0, coreType: 128,
            name: "$nuxie.response.save", url: "", target: "", delay: 0, properties: fields)
        let captured = try XCTUnwrap(ExperienceResponseSaveRequest.capture(.reportedEvent(event),
            snapshot: snapshot, catalog: native.catalog, policy: release.valuePolicy))
        _ = try await native.sessions.mutate([
            .setNumber(instance: native.reference, path: "responses:feedback/stars", value: 5),
        ])
        XCTAssertEqual(captured.form, "feedback")
        XCTAssertEqual(captured.awaitTrigger, "state/save:one:click:0")
        XCTAssertEqual(captured.answers, ["stars": .number(4)])
        XCTAssertEqual(captured.kept, [], "A save keeps only the values it names")
        let script = try XCTUnwrap(ExperienceResponseSaveRequest.capture(
            .hostCommand(name: "$nuxie.response.save", payload: .object([fields[0]])),
            snapshot: snapshot, catalog: native.catalog, policy: release.valuePolicy))
        XCTAssertNil(try ExperienceResponseSaveRequest.capture(
            .hostCommand(name: "ordinary", payload: .object([fields[0]])),
            snapshot: snapshot, catalog: native.catalog, policy: release.valuePolicy))
        XCTAssertNil(script.awaitTrigger)
        XCTAssertEqual(script.answers, captured.answers)
        // A kept value lives in the screen's state and needs an await to keep it for.
        let keep = { (path: String) in ExperienceInteractiveField(key: "keep:stars", value: .bytes(Data(path.utf8))) }
        for invalid in [[fields[0], fields[0]], [.init(key: "form", value: .number(1))],
                        [.init(key: "form", value: .string("missing"))],
                        [fields[0], .init(key: "awaitTrigger", value: .string(""))],
                        [fields[0], fields[1], keep("responses:feedback/stars")],
                        [fields[0], fields[1], keep("state/await:one/stars")],
                        [fields[0], fields[1], keep("state/await:absent:stars")],
                        [fields[0], keep("state/await:one:click:0:stars")]] {
            XCTAssertThrowsError(try ExperienceResponseSaveRequest.capture(
                .hostCommand(name: "$nuxie.response.save", payload: .object(invalid)),
                snapshot: snapshot, catalog: native.catalog, policy: release.valuePolicy))
        }
    }

    func testPublishedF5ReadsLiveAnswersWithoutFilteringMarkingFailures() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("release.json")))
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: release.valuePolicy.native)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let prepared = try await run.native(in: file)
        let native = try XCTUnwrap(prepared)
        let oracle = try JSONDecoder().decode([String: ExactJSONObject<JourneyReleaseJSONValue>].self,
            from: Data(contentsOf: directory.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("events/response-native-sheets.json")))
        let initial = try await native.sessions.snapshot(native.reference)
        guard case .referencedInstance(let feedbackID) = initial.values.first(where: {
            $0.ownerInstanceID == initial.rootInstanceID && $0.name == "responses:feedback"
        })?.value, case .list(let ids) = initial.values.first(where: {
            $0.ownerInstanceID == feedbackID && $0.name == "interests"
        })?.value else { return XCTFail("Published response list is absent") }
        let focus = try await native.sessions.acquireListItem(owner: native.reference,
            path: "responses:feedback/interests", index: 1, expectedIdentity: ids[1])
        let empty = try await run.responseAnswers(form: "feedback", policy: release.valuePolicy)
        XCTAssertEqual(empty, oracle["initial"])
        _ = try await native.sessions.mutate([
            .setNumber(instance: native.reference, path: "responses:feedback/stars", value: 0),
            .setString(instance: native.reference, path: "responses:feedback/email", value: Data("invalid".utf8)),
            .setString(instance: native.reference, path: "responses:feedback/comment", value: Data("hello".utf8)),
            .setBool(instance: native.reference, path: "responses:onboarding/wants_reminder", value: false),
            .setEnumeration(instance: native.reference, path: "responses:onboarding/italian_level", value: 1),
            .setBool(instance: focus, path: "picked", value: true),
        ])
        let answers = try await run.responseAnswers(form: "feedback", policy: release.valuePolicy)
        XCTAssertEqual(answers, oracle["feedback"])
        let onboarding = try await run.responseAnswers(form: "onboarding", policy: release.valuePolicy)
        XCTAssertEqual(onboarding, oracle["onboarding"])
        _ = try await native.sessions.mutate([
            .setBool(instance: native.reference, path: "responses:feedback/isset:stars", value: false),
            .setBool(instance: focus, path: "picked", value: false),
            .setString(instance: native.reference, path: "responses:feedback/email", value: Data()),
            .setString(instance: native.reference, path: "responses:feedback/comment", value: Data()),
        ])
        let cleared = try await run.responseAnswers(form: "feedback", policy: release.valuePolicy)
        XCTAssertEqual(cleared, oracle["cleared"])
    }

    func testBadPolicyFailsPreparationBeforeASessionExists() async throws {
        let bytes = try Data(contentsOf: SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("run-values/screen.riv"))
        let rule = NuxieNativeValueRule(model: "MissingModel", property: "days", kind: 2, mode: 1,
            numberBound: 25, text: "", values: [], pickedProperty: "", boundFlags: 0,
            minimum: 0, maximum: 0, code: "max", message: "At most 25")
        do {
            _ = try await NuxieNativePreparedFile.prepare(bytes: bytes,
                valuePolicy: .init(rules: [rule], groups: []))
            XCTFail("An invalid native table must fail preparation")
        } catch { }
    }

    private static var stateRulesFixture: URL {
        SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("state-rules/policy.json")
    }

    private func stateRulesFixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.stateRulesFixture)) as? [String: Any])
    }

    private func policyRoot(stateRules: Any) -> [String: Any] {
        ["state": [String: Any](), "responses": [String: Any](), "ruleGroups": [Any](), "stateRules": stateRules]
    }

    func testStateRulesValidateAndInstallBesideFormRules() throws {
        let fixture = try stateRulesFixture()
        let records = try XCTUnwrap(fixture["stateRules"] as? [[String: Any]])
        try JourneyReleaseValuePolicy.validate(policyRoot(stateRules: records))
        let bytes = try JSONSerialization.data(withJSONObject: policyRoot(stateRules: records))
        let policy = try JSONDecoder().decode(JourneyReleaseValuePolicy.self, from: bytes)
        let native = policy.native.rules
        XCTAssertEqual(native.count, records.count)
        for (rule, record) in zip(native, records) {
            XCTAssertEqual(rule.model, record["model"] as? String)
            XCTAssertEqual(rule.property, record["property"] as? String)
            XCTAssertEqual(rule.kind, record["kind"] as? UInt32)
            XCTAssertEqual(rule.mode, 1, "\(rule.code) refuses on a value in state")
            XCTAssertEqual(rule.pickedProperty, record["picked_property"] as? String)
        }
        // A release without state rules is unchanged.
        try JourneyReleaseValuePolicy.validate(["state": [String: Any](), "responses": [String: Any](), "ruleGroups": [Any]()])
    }

    func testStateRulesRefuseEachFixtureCase() throws {
        let cases = try XCTUnwrap(stateRulesFixture()["refused"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for refused in cases {
            let rule = try XCTUnwrap(refused["rule"])
            XCTAssertThrowsError(try JourneyReleaseValuePolicy.validate(policyRoot(stateRules: [rule])),
                refused["case"] as? String ?? "")
        }
        XCTAssertThrowsError(try JourneyReleaseValuePolicy.validate(policyRoot(stateRules: ["not a rule"])))
    }

    func testStateRulesKeepTheLastValueThatHeldThemOnThePublishedScreen() async throws {
        let engine = try XCTUnwrap(stateRulesFixture()["engine"] as? [String: Any])
        let rules = try XCTUnwrap(engine["rules"] as? [[String: Any]])
        let property = try XCTUnwrap(engine["property"] as? String)
        let policy = try JSONDecoder().decode(JourneyReleaseValuePolicy.self,
            from: JSONSerialization.data(withJSONObject: policyRoot(stateRules: rules)))
        let screen = Self.stateRulesFixture.deletingLastPathComponent()
            .appendingPathComponent(try XCTUnwrap(engine["screen"] as? String))
        let file = try await NuxieNativePreparedFile.prepare(bytes: Data(contentsOf: screen), valuePolicy: policy.native)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: file)
        let native = try XCTUnwrap(result)
        for write in try XCTUnwrap(engine["writes"] as? [[String: Any]]) {
            let value = try XCTUnwrap(write["value"] as? Double)
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: property, value: Float(value))])
            let snapshot = try await native.sessions.snapshot(native.reference)
            let kept = snapshot.values.first { $0.ownerInstanceID == native.reference.rawValue && $0.name == property }?.value
            XCTAssertEqual(kept, .number(Float(try XCTUnwrap(write["kept"] as? Double))), "writing \(value)")
        }
    }

    func testCatalogMarkersUseSameModelAndFlattenedStateNames() throws {
        let fields: [(String, NuxieNativeViewModelPropertyKind)] = [
            ("days", .number), ("isset:days", .bool),
            ("state:enabled", .bool), ("state:isset:enabled", .bool),
            ("choice", .string), ("isset:choice", .bool),
        ]
        let catalog = NuxieNativeViewModelCatalog(schemas: [.init(index: 0, name: "Component",
            propertyRange: 0..<fields.count, authoredInstanceRange: 0..<0,
            defaultAuthoredInstance: nil, isGlobal: false)],
            properties: fields.enumerated().map { index, field in
                .init(schemaIndex: 0, index: index, name: field.0, kind: field.1,
                    referencedSchemaIndex: nil, enumLabels: [])
            }, authoredInstances: [])
        XCTAssertEqual(try NuxieNativeValuePolicy.empty.markers(in: catalog), [
            .init(model: "Component", value: "days", marker: "isset:days"),
            .init(model: "Component", value: "state:enabled", marker: "state:isset:enabled"),
        ])
    }
}
#endif
