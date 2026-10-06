#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceRunSnapshotTests: XCTestCase {
    func testNestedSnapshotKeepsScalarValuesAndRecreatesNativeMutations() throws {
        let native = NuxieNativeViewModelSnapshot(rootInstanceID: 10, instances: [
            .init(id: 10, schemaIndex: 0, valueRange: 0..<1),
            .init(id: 20, schemaIndex: 1, valueRange: 1..<4)
        ], values: [
            .init(ownerInstanceID: 10, propertyIndex: 0, name: "trip", value: .referencedInstance(20)),
            .init(ownerInstanceID: 20, propertyIndex: 0, name: "name", value: .bytes(Data("Italy".utf8))),
            .init(ownerInstanceID: 20, propertyIndex: 1, name: "days", value: .number(30)),
            .init(ownerInstanceID: 20, propertyIndex: 2, name: "reminder", value: .bool(false))
        ])
        let catalog = NuxieNativeViewModelCatalog(schemas: [], properties: [
            .init(schemaIndex: 0, index: 0, name: "trip", kind: .viewModel, referencedSchemaIndex: 1, enumLabels: []),
            .init(schemaIndex: 1, index: 0, name: "name", kind: .string, referencedSchemaIndex: nil, enumLabels: []),
            .init(schemaIndex: 1, index: 1, name: "days", kind: .number, referencedSchemaIndex: nil, enumLabels: []),
            .init(schemaIndex: 1, index: 2, name: "reminder", kind: .bool, referencedSchemaIndex: nil, enumLabels: [])
        ], authoredInstances: [])
        let snapshot = ExperienceRunSnapshot(native: native, catalog: catalog)
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.journeyValues, ["trip/name": .string("Italy"), "trip/days": .number(30), "trip/reminder": .bool(false)])
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 99))
        XCTAssertEqual(try decoded.mutations(for: reference), [
            .setString(instance: reference, path: "trip/name", value: Data("Italy".utf8)),
            .setNumber(instance: reference, path: "trip/days", value: 30),
            .setBool(instance: reference, path: "trip/reminder", value: false)
        ])
    }
}
#endif
