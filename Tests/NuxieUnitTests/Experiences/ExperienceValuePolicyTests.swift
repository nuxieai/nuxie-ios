#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceValuePolicyTests: XCTestCase {
    func testRulesInstallBeforeFirstMutationInEveryFreshGroup() async throws {
        let bytes = try Data(contentsOf: SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("run-values/screen.riv"))
        let rule = NuxieNativeValueRule(model: "Experience", property: "trip_days", kind: 2, mode: 1,
            numberBound: 25, text: "", values: [], pickedProperty: "", boundFlags: 0,
            minimum: 0, maximum: 0, code: "max", message: "At most 25")
        let file = try await NuxieNativePreparedFile.prepare(bytes: bytes,
            valuePolicy: .init(rules: [rule], groups: []))
        for _ in 0..<2 {
            let run = ExperienceRunValues()
            addTeardownBlock { await run.retire() }
            let result = try await run.native(in: file)
            let native = try XCTUnwrap(result)
            _ = try await native.sessions.mutate([
                .setNumber(instance: native.reference, path: "trip_days", value: 30),
            ])
            let rejected = try await native.sessions.snapshot(native.reference)
            XCTAssertEqual(rejected.values.first { $0.name == "trip_days" }?.value, .number(23))
            _ = try await native.sessions.mutate([
                .setNumber(instance: native.reference, path: "trip_days", value: 24),
            ])
            let accepted = try await native.sessions.snapshot(native.reference)
            XCTAssertEqual(accepted.values.first { $0.name == "trip_days" }?.value, .number(24))
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
