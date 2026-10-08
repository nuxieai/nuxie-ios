#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceValuePolicyTests: XCTestCase {
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
