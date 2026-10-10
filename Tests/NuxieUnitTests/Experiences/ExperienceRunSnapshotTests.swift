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
        let restored = ExperienceRunValues(snapshot: decoded)
        addTeardownBlock { await restored.retire() }
        _ = try await restored.native(in: prepared)
        let recovered = try await restored.journeyValues()
        XCTAssertEqual(recovered["goals"], expected)

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

    func testListRestoreKeepsEditedAuthoredRowsAndRemovesExtraRows() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let initial = try await native.sessions.snapshot(native.reference)
        let ids = try listIDs(initial)
        let first = try await native.sessions.acquireListItem(owner: native.reference,
            path: "goals", index: 0, expectedIdentity: ids[0])
        _ = try await native.sessions.mutate([
            .setString(instance: first, path: "title", value: Data("Edited Read".utf8)),
            .listMove(instance: native.reference, path: "goals", from: 0, to: 1),
        ])
        let captured = try await run.snapshot()
        let checkpoint = try XCTUnwrap(captured)
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(checkpoint))
        let target = ExperienceRunValues()
        addTeardownBlock { await target.retire() }
        let targetResult = try await target.native(in: prepared)
        let fresh = try XCTUnwrap(targetResult)
        let freshSnapshot = try await fresh.sessions.snapshot(fresh.reference)
        let freshIDs = try listIDs(freshSnapshot)
        let schema = try XCTUnwrap(freshSnapshot.instances.first { $0.id == freshIDs[0] }?.schemaIndex)
        let extra = try await fresh.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: nil)
        _ = try await fresh.sessions.mutate([
            .setString(instance: extra, path: "title", value: Data("Discard".utf8)),
            .listInsert(instance: fresh.reference, path: "goals", index: 2, value: extra),
        ])
        try await XCTUnwrap(decoded.lists).restore(sessions: fresh.sessions, root: fresh.reference)
        let recovered = try await fresh.sessions.snapshot(fresh.reference)
        XCTAssertEqual(try listIDs(recovered), [freshIDs[1], freshIDs[0]])
        XCTAssertEqual(recovered.values.first { $0.ownerInstanceID == freshIDs[0] && $0.name == "title" }?.value,
            .bytes(Data("Edited Read".utf8)))
        let separate = ExperienceRunValues()
        addTeardownBlock { await separate.retire() }
        _ = try await separate.native(in: prepared)
        let separateValues = try await separate.journeyValues()
        XCTAssertEqual(separateValues["goals"], .array([
            .object(["title": .string("Read")]), .object(["title": .string("Walk")]),
        ]))
    }

    func testEmptyListCheckpointRestoresAndCanBeCheckpointedAgain() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        _ = try await native.sessions.mutate([.listRemove(instance: native.reference, path: "goals", index: 1),
            .listRemove(instance: native.reference, path: "goals", index: 0)])
        let snapshot = try await run.snapshot()
        let checkpoint = try XCTUnwrap(snapshot)
        let restored = ExperienceRunValues(snapshot: checkpoint)
        addTeardownBlock { await restored.retire() }
        _ = try await restored.native(in: prepared)
        let values = try await restored.journeyValues()
        XCTAssertEqual(values["goals"], .array([]))
        let nextSnapshot = try await restored.snapshot()
        let again = ExperienceRunValues(snapshot: try XCTUnwrap(nextSnapshot))
        addTeardownBlock { await again.retire() }
        _ = try await again.native(in: prepared)
        let againValues = try await again.journeyValues()
        XCTAssertEqual(againValues["goals"], .array([]))
    }

    func testCheckpointKeepsReferenceToRetainedListRow() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("checkpoint-aliases")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let initial = try await native.sessions.snapshot(native.reference)
        let ids = try listIDs(initial)
        let selected = try await native.sessions.acquireListItem(owner: native.reference,
            path: "goals", index: 1, expectedIdentity: ids[1])
        _ = try await native.sessions.mutate([
            .setViewModel(instance: native.reference, path: "selected", value: selected),
        ])
        let captured = try await run.snapshot()
        let checkpoint = try XCTUnwrap(captured)
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(checkpoint))
        let restored = ExperienceRunValues(snapshot: decoded)
        addTeardownBlock { await restored.retire() }
        let restoredResult = try await restored.native(in: prepared)
        let fresh = try XCTUnwrap(restoredResult)
        let before = try await fresh.sessions.snapshot(fresh.reference)
        let restoredIDs = try listIDs(before)
        XCTAssertEqual(before.values.first { $0.ownerInstanceID == before.rootInstanceID && $0.name == "selected" }?.value,
            .referencedInstance(restoredIDs[1]))
        _ = try await fresh.sessions.mutate([
            .setString(instance: fresh.reference, path: "selected/title", value: Data("Edited through selected".utf8)),
        ])
        let after = try await fresh.sessions.snapshot(fresh.reference)
        XCTAssertEqual(after.values.first { $0.ownerInstanceID == restoredIDs[0] && $0.name == "title" }?.value,
            .bytes(Data("A".utf8)))
        XCTAssertEqual(after.values.first { $0.ownerInstanceID == restoredIDs[1] && $0.name == "title" }?.value,
            .bytes(Data("Edited through selected".utf8)))
    }

    func testRemovedRowStillHeldByReferenceSurvivesRestart() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("checkpoint-aliases")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        for addedDuringRun in [false, true] {
            let run = ExperienceRunValues()
            addTeardownBlock { await run.retire() }
            let result = try await run.native(in: prepared)
            let native = try XCTUnwrap(result)
            let initial = try await native.sessions.snapshot(native.reference)
            let ids = try listIDs(initial)
            let selected: NuxieNativeViewModelReference
            let removedIndex: Int
            if addedDuringRun {
                let schema = try XCTUnwrap(initial.instances.first { $0.id == ids[0] }?.schemaIndex)
                selected = try await native.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: nil)
                _ = try await native.sessions.mutate([
                    .setString(instance: selected, path: "title", value: Data("Added".utf8)),
                    .listInsert(instance: native.reference, path: "goals", index: 2, value: selected),
                ])
                removedIndex = 2
            } else {
                selected = try await native.sessions.acquireListItem(owner: native.reference,
                    path: "goals", index: 1, expectedIdentity: ids[1])
                removedIndex = 1
            }
            _ = try await native.sessions.mutate([
                .setViewModel(instance: native.reference, path: "selected", value: selected),
                .listRemove(instance: native.reference, path: "goals", index: removedIndex),
            ])
            let captured = try await run.snapshot()
            let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self,
                from: JSONEncoder().encode(try XCTUnwrap(captured)))
            let restored = ExperienceRunValues(snapshot: decoded)
            addTeardownBlock { await restored.retire() }
            let restoredResult = try await restored.native(in: prepared)
            let fresh = try XCTUnwrap(restoredResult)
            let before = try await fresh.sessions.snapshot(fresh.reference)
            let remaining = try listIDs(before)
            XCTAssertEqual(remaining.count, addedDuringRun ? 2 : 1)
            let selectedValue = try XCTUnwrap(before.values.first {
                $0.ownerInstanceID == before.rootInstanceID && $0.name == "selected"
            })
            guard case .referencedInstance(let selectedID) = selectedValue.value else {
                XCTFail("Selected row must remain a reference"); continue
            }
            XCTAssertFalse(remaining.contains(selectedID))
            XCTAssertEqual(before.values.first { $0.ownerInstanceID == selectedID && $0.name == "title" }?.value,
                .bytes(Data((addedDuringRun ? "Added" : "B").utf8)))
            _ = try await fresh.sessions.mutate([
                .setString(instance: fresh.reference, path: "selected/title", value: Data("Detached edit".utf8)),
            ])
            let after = try await fresh.sessions.snapshot(fresh.reference)
            XCTAssertEqual(after.values.first { $0.ownerInstanceID == remaining[0] && $0.name == "title" }?.value,
                .bytes(Data("A".utf8)))
        }
    }

    func testDistinctCheckpointNodesCannotResolveToOneAuthoredRow() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let captured = try await run.snapshot()
        let checkpoint = try XCTUnwrap(captured)
        var nodes = try XCTUnwrap(checkpoint.lists).nodes
        XCTAssertEqual(nodes.count, 3)
        guard nodes.count == 3 else { return }
        let second = nodes[2]
        nodes[2] = .init(schema: second.schema, origin: nodes[1].origin,
            fields: second.fields, lists: second.lists, references: second.references)
        let before = try await native.sessions.snapshot(native.reference)
        do {
            try await ExperienceRunListSnapshot(nodes: nodes).restore(sessions: native.sessions, root: native.reference)
            XCTFail("Distinct nodes must not collapse to one authored identity")
        } catch ExperienceInteractiveScreenError.stateContract { }
        let after = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(after, before, "Malformed identity mapping must fail before writes")
    }

    func testPublishedListChildAcquisitionKeepsIdentityAndRejectsStaleSlot() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let prepared = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        let before = try await native.sessions.snapshot(native.reference)
        let ids = try listIDs(before)
        XCTAssertEqual(ids.count, 2)
        guard ids.count == 2 else { return }
        let child = try await native.sessions.acquireListItem(owner: native.reference,
            path: "goals", index: 0, expectedIdentity: ids[0])
        let unchanged = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(unchanged, before, "Acquisition must not mutate the list")
        _ = try await native.sessions.mutate([
            .setString(instance: child, path: "title", value: Data("Rest".utf8)),
            .listMove(instance: native.reference, path: "goals", from: 0, to: 1),
        ])
        let moved = try await native.sessions.snapshot(native.reference)
        XCTAssertEqual(try listIDs(moved), [ids[1], ids[0]])
        XCTAssertEqual(moved.values.first { $0.ownerInstanceID == ids[0] && $0.name == "title" }?.value,
            .bytes(Data("Rest".utf8)))
        do {
            _ = try await native.sessions.acquireListItem(owner: native.reference,
                path: "goals", index: 0, expectedIdentity: ids[0])
            XCTFail("An old list position must not acquire a different row")
        } catch NuxieNativeRuntimeError.invalidNativeValue { }
        let retained = try await native.sessions.acquireListItem(owner: native.reference,
            path: "goals", index: 1, expectedIdentity: ids[0])
        XCTAssertEqual(retained, child)
        _ = try await native.sessions.mutate([
            .listRemove(instance: native.reference, path: "goals", index: 1),
            .setString(instance: child, path: "title", value: Data("Still retained".utf8)),
        ])
        let detached = try await native.sessions.snapshot(child)
        XCTAssertEqual(detached.rootInstanceID, ids[0])
        XCTAssertEqual(detached.values.first { $0.name == "title" }?.value,
            .bytes(Data("Still retained".utf8)))
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

    func testListCaptureDoesNotCreateARowForAnUnsetReference() throws {
        struct Vector: Decodable {
            let root: UInt64; let row: UInt64; let unsetReference: UInt64
            let title: String; let expectedNodeCount: Int
        }
        let path = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("checkpoint-aliases/null-reference.json")
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: path))
        let native = NuxieNativeViewModelSnapshot(rootInstanceID: vector.root, instances: [
            .init(id: vector.root, schemaIndex: 0, valueRange: 0..<2),
            .init(id: vector.row, schemaIndex: 1, valueRange: 2..<3),
        ], values: [
            .init(ownerInstanceID: vector.root, propertyIndex: 0, name: "goals", value: .list([vector.row])),
            .init(ownerInstanceID: vector.root, propertyIndex: 1, name: "optional", value: .referencedInstance(vector.unsetReference)),
            .init(ownerInstanceID: vector.row, propertyIndex: 0, name: "title", value: .bytes(Data(vector.title.utf8))),
        ])
        let catalog = NuxieNativeViewModelCatalog(schemas: [], properties: [
            .init(schemaIndex: 0, index: 0, name: "goals", kind: .list, referencedSchemaIndex: 1, enumLabels: []),
            .init(schemaIndex: 0, index: 1, name: "optional", kind: .viewModel, referencedSchemaIndex: 1, enumLabels: []),
            .init(schemaIndex: 1, index: 0, name: "title", kind: .string, referencedSchemaIndex: nil, enumLabels: []),
        ], authoredInstances: [])
        let checkpoint = ExperienceRunSnapshot(native: native, catalog: catalog,
            origins: ExperienceRunListSnapshot.authoredOrigins(native), authoredIDs: [vector.root, vector.row])
        let decoded = try JSONDecoder().decode(ExperienceRunSnapshot.self, from: JSONEncoder().encode(checkpoint))
        let graph = try XCTUnwrap(decoded.lists)
        XCTAssertEqual(graph.nodes.count, vector.expectedNodeCount)
        XCTAssertTrue(graph.nodes.allSatisfy { $0.schema >= 0 && $0.references.isEmpty })
        XCTAssertEqual(decoded.journeyValues["goals"], .array([.object(["title": .string(vector.title)])]))
    }

    func testNestedListProjectionBuildsObjectsWithinRows() {
        let snapshot = ExperienceRunListSnapshot(nodes: [
            .init(schema: 0, origin: [], fields: [], lists: [.init(path: "goals", items: [1])], references: []),
            .init(schema: 1, origin: nil, fields: [
                .init(path: "detail/name", kind: NuxieNativeViewModelPropertyKind.string.rawValue,
                    value: .bytes(Data("Trip".utf8))),
            ], lists: [.init(path: "detail/children", items: [2])], references: []),
            .init(schema: 2, origin: nil, fields: [
                .init(path: "title", kind: NuxieNativeViewModelPropertyKind.string.rawValue,
                    value: .bytes(Data("Walk".utf8))),
            ], lists: [], references: []),
        ])
        XCTAssertEqual(snapshot.journeyLists["goals"], .array([
            .object(["detail": .object(["name": .string("Trip"),
                "children": .array([.object(["title": .string("Walk")])])])]),
        ]))
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
