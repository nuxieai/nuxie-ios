import Foundation
#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#endif

/// List references use checkpoint-local ordinals, never native identities.
struct ExperienceRunListSnapshot: Codable, Equatable, Sendable {
    struct OriginStep: Codable, Equatable, Sendable {
        let path: String
        let index: Int
    }
    struct List: Codable, Equatable, Sendable {
        let path: String
        let items: [Int]
    }
    struct Reference: Codable, Equatable, Sendable {
        let path: String
        let target: Int
    }
    struct Node: Codable, Equatable, Sendable {
        let schema: Int
        let origin: [OriginStep]?
        let fields: [ExperienceRunSnapshot.Field]
        let lists: [List]
        let references: [Reference]
    }
    let nodes: [Node]

    init(nodes: [Node]) { self.nodes = nodes }

    var journeyLists: ExactJSONObject<JourneyReleaseJSONValue> {
        func object(_ index: Int, ancestors: Set<Int>) -> JourneyReleaseJSONValue? {
            guard nodes.indices.contains(index), !ancestors.contains(index) else { return nil }
            let node = nodes[index]
            var values = ExactJSONObject<JourneyReleaseJSONValue>()
            func assign(_ path: ArraySlice<Substring>, value: JourneyReleaseJSONValue,
                into object: inout ExactJSONObject<JourneyReleaseJSONValue>) {
                guard let first = path.first else { return }
                let key = String(first)
                if path.count == 1 { object[key] = value; return }
                var child: ExactJSONObject<JourneyReleaseJSONValue>
                if case .object(let existing) = object[key] { child = existing } else { child = [:] }
                assign(path.dropFirst(), value: value, into: &child)
                object[key] = .object(child)
            }
            for (path, value) in ExperienceRunSnapshot(fields: node.fields).journeyValues {
                assign(path.split(separator: "/")[...], value: value, into: &values)
            }
            for list in node.lists {
                let items = list.items.compactMap { object($0, ancestors: ancestors.union([index])) }
                assign(list.path.split(separator: "/")[...], value: .array(items), into: &values)
            }
            return .object(values)
        }
        var result = ExactJSONObject<JourneyReleaseJSONValue>()
        for list in nodes.first?.lists ?? [] {
            result[list.path] = .array(list.items.compactMap { object($0, ancestors: [0]) })
        }
        return result
    }

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    /// Addresses refer to the untouched authored graph, before any run writes.
    static func authoredOrigins(_ native: NuxieNativeViewModelSnapshot) -> [UInt64: [OriginStep]] {
        var result: [UInt64: [OriginStep]] = [native.rootInstanceID: []]
        func visit(_ id: UInt64, origin: [OriginStep]) {
            for (path, children) in listEntries(native, root: id) {
                for (index, child) in children.enumerated() where result[child] == nil {
                    let address = origin + [.init(path: path, index: index)]
                    result[child] = address
                    visit(child, origin: address)
                }
            }
        }
        visit(native.rootInstanceID, origin: [])
        return result
    }

    init?(native: NuxieNativeViewModelSnapshot, catalog: NuxieNativeViewModelCatalog,
        origins: [UInt64: [OriginStep]], authoredIDs: Set<UInt64>) {
        guard !Self.listEntries(native, root: native.rootInstanceID).isEmpty else { return nil }
        let instances = Dictionary(uniqueKeysWithValues: native.instances.map { ($0.id, $0) })
        var indices: [UInt64: Int] = [:]
        var pending: [Node?] = []
        var identities: [UInt64] = []
        func visit(_ id: UInt64) -> Int {
            if let index = indices[id] { return index }
            let index = pending.count
            indices[id] = index
            pending.append(nil)
            identities.append(id)
            let lists = Self.listEntries(native, root: id).map { path, children in
                List(path: path, items: children.map(visit))
            }
            // A removed row can remain alive through an ordinary reference. Retain its
            // authored origin, or recreate it once if it was added during this run.
            func visitRetainedRows(_ owner: UInt64, ancestors: Set<UInt64>) {
                guard !ancestors.contains(owner), let instance = instances[owner] else { return }
                for entry in native.values[instance.valueRange] {
                    guard case .referencedInstance(let child) = entry.value, child != 0 else { continue }
                    if origins[child] != nil || !authoredIDs.contains(child) {
                        _ = visit(child)
                    } else {
                        visitRetainedRows(child, ancestors: ancestors.union([owner]))
                    }
                }
            }
            visitRetainedRows(id, ancestors: [])
            pending[index] = Node(schema: instances[id]?.schemaIndex ?? -1, origin: origins[id],
                fields: ExperienceRunSnapshot.captureFields(native: native, catalog: catalog, root: id), lists: lists, references: [])
            return index
        }
        _ = visit(native.rootInstanceID)
        nodes = pending.enumerated().compactMap { index, node in
            guard let node else { return nil }
            let id = identities[index]
            var references: [Reference] = []
            func visitReferences(_ owner: UInt64, prefix: String, ancestors: Set<UInt64>) {
                guard !ancestors.contains(owner), let instance = instances[owner] else { return }
                for entry in native.values[instance.valueRange] {
                    guard case .referencedInstance(let target) = entry.value, target != 0 else { continue }
                    let path = prefix + entry.name
                    if let targetIndex = indices[target] {
                        references.append(.init(path: path, target: targetIndex))
                    } else {
                        visitReferences(target, prefix: path + "/", ancestors: ancestors.union([owner]))
                    }
                }
            }
            visitReferences(id, prefix: "", ancestors: [])
            return Node(schema: node.schema, origin: node.origin, fields: node.fields,
                lists: node.lists, references: references)
        }
    }

    private static func listEntries(_ native: NuxieNativeViewModelSnapshot, root: UInt64)
        -> [(String, [UInt64])] {
        let instances = Dictionary(uniqueKeysWithValues: native.instances.map { ($0.id, $0) })
        var result: [(String, [UInt64])] = []
        func visit(_ id: UInt64, prefix: String, ancestors: Set<UInt64>) {
            guard !ancestors.contains(id), let instance = instances[id] else { return }
            for entry in native.values[instance.valueRange] {
                switch entry.value {
                case .referencedInstance(let child):
                    visit(child, prefix: prefix + entry.name + "/", ancestors: ancestors.union([id]))
                case .list(let children): result.append((prefix + entry.name, children))
                default: break
                }
            }
        }
        visit(root, prefix: "", ancestors: [])
        return result
    }

    func restore(sessions: NuxieNativeSessionGroup, root: NuxieNativeViewModelReference) async throws {
        guard !nodes.isEmpty else { throw invalidSnapshot() }
        let initial = try await sessions.snapshot(root)
        guard nodes[0].schema == initial.instances.first(where: { $0.id == initial.rootInstanceID })?.schemaIndex,
            nodes.allSatisfy({ node in
                node.schema >= 0 && node.references.allSatisfy { nodes.indices.contains($0.target) } &&
                    node.lists.allSatisfy { list in list.items.allSatisfy { nodes.indices.contains($0) } }
            }) else { throw invalidSnapshot() }
        var references = [root]
        // Resolve every authored address while the fresh defaults are untouched.
        for node in nodes.dropFirst() {
            if let origin = node.origin {
                guard !origin.isEmpty else { throw invalidSnapshot() }
                var reference = root
                for step in origin {
                    let snapshot = try await sessions.snapshot(reference)
                    guard let ids = Self.listEntries(snapshot, root: snapshot.rootInstanceID)
                        .first(where: { $0.0 == step.path })?.1, ids.indices.contains(step.index) else {
                        throw invalidSnapshot()
                    }
                    reference = try await sessions.acquireListItem(owner: reference, path: step.path,
                        index: step.index, expectedIdentity: ids[step.index])
                }
                let snapshot = try await sessions.snapshot(reference)
                guard snapshot.instances.first(where: { $0.id == snapshot.rootInstanceID })?.schemaIndex == node.schema else {
                    throw invalidSnapshot()
                }
                references.append(reference)
            } else {
                references.append(try await sessions.makeViewModel(schemaIndex: node.schema, authoredInstanceIndex: nil))
            }
        }
        guard Set(references.map(\.rawValue)).count == references.count else { throw invalidSnapshot() }
        // Reconnect references to retained rows before writing any flattened scalar paths.
        for (index, node) in nodes.enumerated() {
            let links = node.references.map {
                NuxieNativeViewModelMutation.setViewModel(instance: references[index],
                    path: $0.path, value: references[$0.target])
            }
            if !links.isEmpty { _ = try await sessions.mutate(links) }
        }
        for (index, node) in nodes.enumerated() {
            let reference = references[index]
            let fields = try ExperienceRunSnapshot(fields: node.fields).mutations(for: reference)
            if !fields.isEmpty { _ = try await sessions.mutate(fields) }
            for list in node.lists {
                let snapshot = try await sessions.snapshot(reference)
                guard var current = Self.listEntries(snapshot, root: snapshot.rootInstanceID)
                    .first(where: { $0.0 == list.path })?.1 else { throw invalidSnapshot() }
                let wanted = list.items.map { references[$0] }
                var mutations: [NuxieNativeViewModelMutation] = []
                for (position, child) in wanted.enumerated() {
                    if position < current.count, current[position] == child.rawValue { continue }
                    if let from = current.indices.dropFirst(position).first(where: { current[$0] == child.rawValue }) {
                        mutations.append(.listMove(instance: reference, path: list.path, from: from, to: position))
                        current.insert(current.remove(at: from), at: position)
                    } else {
                        mutations.append(.listInsert(instance: reference, path: list.path, index: position, value: child))
                        current.insert(child.rawValue, at: position)
                    }
                }
                while current.count > wanted.count {
                    let position = current.count - 1
                    mutations.append(.listRemove(instance: reference, path: list.path, index: position))
                    current.removeLast()
                }
                if !mutations.isEmpty { _ = try await sessions.mutate(mutations) }
            }
        }
    }

    private func invalidSnapshot() -> ExperienceInteractiveScreenError {
        .stateContract("Invalid run list snapshot")
    }
    #endif
}
