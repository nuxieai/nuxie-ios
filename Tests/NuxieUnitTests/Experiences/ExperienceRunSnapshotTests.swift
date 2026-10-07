#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceRunSnapshotTests: XCTestCase {
    func testPublishedGoalsCheckpointKeepsChangedOrder() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        struct Oracle: Decodable {
            struct Goal: Decodable { let title: String }
            struct Values: Decodable { let goals: [Goal] }
            let startingValues: Values
            let snapshot: Values
        }
        let oracle = try JSONDecoder().decode(Oracle.self,
            from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let nativeResult = try await run.native(in: prepared)
        let native = try XCTUnwrap(nativeResult)
        let before = try await native.sessions.snapshot(native.reference)
        let list = try XCTUnwrap(before.values.first { $0.ownerInstanceID == before.rootInstanceID && $0.name == "goals" })
        guard case .list(let ids) = list.value else { return XCTFail("Published goals must be a native list") }
        let initialTitles = ids.map { id in
            before.values.first { $0.ownerInstanceID == id && $0.name == "title" }?.value
        }
        XCTAssertEqual(initialTitles, oracle.startingValues.goals.map { .bytes(Data($0.title.utf8)) })
        let schema = try XCTUnwrap(before.instances.first { $0.id == ids.first }?.schemaIndex)
        let inserted = try await native.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: 0)
        _ = try await native.sessions.mutate([
            .setString(instance: inserted, path: "title", value: Data("Sleep".utf8)),
            .listMove(instance: native.reference, path: "goals", from: 1, to: 0),
            .listInsert(instance: native.reference, path: "goals", index: 1, value: inserted),
        ])
        let captured = try await run.snapshot()
        let checkpoint = try XCTUnwrap(captured)
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(checkpoint))
        let expected: JourneyReleaseJSONValue = .array(oracle.snapshot.goals.map { .object(["title": .string($0.title)]) })
        XCTAssertEqual(decoded.journeyValues["goals"], expected)

    }

    func testListCheckpointPreservesRepeatedReferencesAndEqualDistinctRows() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let original = try await native.sessions.snapshot(native.reference)
        let ids = try listIDs(original)
        let schema = try XCTUnwrap(original.instances.first { $0.id == ids.first }?.schemaIndex)
        let repeated = try await native.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: 0)
        let distinct = try await native.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: 0)
        _ = try await native.sessions.mutate([
            .setString(instance: repeated, path: "title", value: Data("Same".utf8)),
            .setString(instance: distinct, path: "title", value: Data("Same".utf8)),
            .listClear(instance: native.reference, path: "goals"),
            .listInsert(instance: native.reference, path: "goals", index: 0, value: repeated),
            .listInsert(instance: native.reference, path: "goals", index: 1, value: distinct),
            .listInsert(instance: native.reference, path: "goals", index: 2, value: repeated),
        ])
        let snapshot = try await run.snapshot()
        let checkpoint = try XCTUnwrap(snapshot)
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(checkpoint))
        let restored = ExperienceRunValues(snapshot: decoded)
        addTeardownBlock { await restored.retire() }
        let restoredResult = try await restored.native(in: prepared)
        let target = try XCTUnwrap(restoredResult)
        let final = try await target.sessions.snapshot(target.reference)
        let finalIDs = try listIDs(final)
        XCTAssertEqual(finalIDs.count, 3)
        guard finalIDs.count == 3 else { return }
        XCTAssertEqual(finalIDs[0], finalIDs[2])
        XCTAssertNotEqual(finalIDs[0], finalIDs[1])
    }

    func testPublishedListChildCannotBeAddressedByAnIndexedMutationPath() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let before = try await native.sessions.snapshot(native.reference)
        do {
            _ = try await native.sessions.mutate([
                .setString(instance: native.reference, path: "goals/0/title", value: Data("Edited".utf8)),
            ])
            XCTFail("The staged ABI unexpectedly supports indexed child paths; revisit C19 recovery")
        } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
            XCTAssertEqual(diagnostic.status, .notFound)
        }
        let after = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(after, before)
    }

    private func listIDs(_ snapshot: NuxieNativeViewModelSnapshot) throws -> [UInt64] {
        let value = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "goals"
        })
        guard case .list(let ids) = value.value else {
            throw NSError(domain: "Expected native list", code: 1)
        }
        return ids
    }

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
