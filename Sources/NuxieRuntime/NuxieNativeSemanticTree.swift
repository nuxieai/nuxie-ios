import Foundation

/// Portable semantic ABI values. Platform views consume copied values, never native handles.
package struct NuxieNativeSemanticNode: Equatable, Sendable {
    package static let expanded: UInt32 = 1 << 0
    package static let selected: UInt32 = 1 << 1
    package static let checked: UInt32 = 1 << 2
    package static let mixed: UInt32 = 1 << 3
    package static let toggled: UInt32 = 1 << 4
    package static let required: UInt32 = 1 << 5
    package static let disabled: UInt32 = 1 << 6
    package static let readOnly: UInt32 = 1 << 10
    package static let hidden: UInt32 = 1 << 8
    package static let modal: UInt32 = 1 << 11
    package static let obscured: UInt32 = 1 << 12

    package let id: UInt32
    package let parentID: UInt32?
    package let siblingIndex: UInt32
    package let role: UInt32
    package var stateFlags: UInt32
    package let traitFlags: UInt32
    package let headingLevel: UInt32
    package let actions: UInt32
    package let bounds: CGRect
    package let label: String
    package let value: String
    package let hint: String
    package let collectionID: UInt32?
    package let itemCount: UInt32?
    package let itemPosition: UInt32?

    package init(
        id: UInt32,
        parentID: UInt32?,
        siblingIndex: UInt32,
        role: UInt32,
        stateFlags: UInt32,
        traitFlags: UInt32,
        headingLevel: UInt32,
        actions: UInt32,
        bounds: CGRect,
        label: String,
        value: String,
        hint: String,
        collectionID: UInt32? = nil,
        itemCount: UInt32? = nil,
        itemPosition: UInt32? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.siblingIndex = siblingIndex
        self.role = role
        self.stateFlags = stateFlags
        self.traitFlags = traitFlags
        self.headingLevel = headingLevel
        self.actions = actions
        self.bounds = bounds
        self.label = label
        self.value = stateFlags & Self.obscured == 0 ? value : ""
        self.hint = hint
        self.collectionID = collectionID
        self.itemCount = itemCount
        self.itemPosition = itemPosition
    }
}

package enum NuxieNativeSemanticTreeError: Error, Equatable {
    case tooManyNodes
    case duplicateIdentity(UInt32)
    case missingAncestor(UInt32)
    case cyclicHierarchy
    case invalidModalIdentity(UInt32)
    case invalidCollectionMetadata(UInt32)
}

/// Modal selection is copied from the runtime's rendered occurrence order.
package enum NuxieNativeSemanticModalScope: Equatable, Sendable {
    case none
    case active(UInt32)
    case unresolved
}

/// One copied presented revision. Both native editors and drawn controls receive
/// effective disabled/hidden state; the runtime separately authorizes exact actions.
package struct NuxieNativeSemanticTree: Sendable {
    package let renderRevision: UInt64
    package let treeVersion: UInt64
    package let modalScope: NuxieNativeSemanticModalScope
    package let nodes: [NuxieNativeSemanticNode]

    /// Native editors obey the same captured modal boundary as drawn controls.
    package var exposedNodeIDs: Set<UInt32> {
        switch modalScope {
        case .none:
            return Set(nodes.filter { $0.stateFlags & NuxieNativeSemanticNode.hidden == 0 }.map(\.id))
        case .unresolved:
            return []
        case .active(let id):
            let children = Dictionary(grouping: nodes, by: \.parentID)
            var pending = nodes.filter { $0.id == id }
            var exposed: Set<UInt32> = []
            while let node = pending.popLast() {
                guard node.stateFlags & NuxieNativeSemanticNode.hidden == 0 else { continue }
                exposed.insert(node.id)
                pending.append(contentsOf: children[node.id] ?? [])
            }
            return exposed
        }
    }

    /// Authored depth-first order, independent of snapshot storage order.
    package var visibleReadingOrder: [NuxieNativeSemanticNode] {
        var children: [UInt32?: [(offset: Int, node: NuxieNativeSemanticNode)]] = [:]
        for (offset, node) in nodes.enumerated() {
            children[node.parentID, default: []].append((offset, node))
        }
        for parent in Array(children.keys) {
            children[parent]?.sort { left, right in
                left.node.siblingIndex == right.node.siblingIndex
                    ? left.offset < right.offset : left.node.siblingIndex < right.node.siblingIndex
            }
        }
        var stack = Array((children[nil] ?? []).reversed())
        var ordered: [NuxieNativeSemanticNode] = []
        while let entry = stack.popLast() {
            guard entry.node.stateFlags & NuxieNativeSemanticNode.hidden == 0 else { continue }
            ordered.append(entry.node)
            stack.append(contentsOf: (children[entry.node.id] ?? []).reversed())
        }
        return ordered
    }

    package init(
        renderRevision: UInt64,
        treeVersion: UInt64,
        nodes: [NuxieNativeSemanticNode],
        modalScope: NuxieNativeSemanticModalScope = .none
    ) throws {
        guard nodes.count <= 16_384 else { throw NuxieNativeSemanticTreeError.tooManyNodes }
        var byID: [UInt32: NuxieNativeSemanticNode] = [:]
        for node in nodes {
            guard byID.updateValue(node, forKey: node.id) == nil else {
                throw NuxieNativeSemanticTreeError.duplicateIdentity(node.id)
            }
        }
        var positions: [UInt32: Set<UInt32>] = [:]
        var members: [UInt32: Int] = [:]
        for node in nodes {
            let validRole = (node.itemCount == nil || node.role == NuxieNativeSemanticRole.list.rawValue)
                && (node.itemPosition == nil || node.role == NuxieNativeSemanticRole.listItem.rawValue)
                && (node.collectionID == nil || node.role == NuxieNativeSemanticRole.listItem.rawValue)
            guard validRole, node.itemPosition == nil || node.collectionID != nil else {
                throw NuxieNativeSemanticTreeError.invalidCollectionMetadata(node.id)
            }
            guard let ownerID = node.collectionID else { continue }
            guard let owner = byID[ownerID], owner.role == NuxieNativeSemanticRole.list.rawValue else {
                throw NuxieNativeSemanticTreeError.invalidCollectionMetadata(node.id)
            }
            members[ownerID, default: 0] += 1
            if let total = owner.itemCount, members[ownerID, default: 0] > Int(total) {
                throw NuxieNativeSemanticTreeError.invalidCollectionMetadata(node.id)
            }
            if let position = node.itemPosition {
                guard owner.itemCount.map({ position < $0 }) ?? true,
                      positions[ownerID, default: []].insert(position).inserted else {
                    throw NuxieNativeSemanticTreeError.invalidCollectionMetadata(node.id)
                }
            }
        }
        let inheritedMask = NuxieNativeSemanticNode.disabled | NuxieNativeSemanticNode.hidden
        var inheritedStates: [UInt32: UInt32] = [:]
        var nearestLists: [UInt32: UInt32] = [:]
        // Resolve each ancestor once. Deep authored trees must not consume the
        // call stack or turn every captured frame into a quadratic traversal.
        for node in nodes {
            var path: [NuxieNativeSemanticNode] = []
            var visiting: Set<UInt32> = []
            var current: NuxieNativeSemanticNode? = node
            while let item = current, inheritedStates[item.id] == nil {
                guard visiting.insert(item.id).inserted else {
                    throw NuxieNativeSemanticTreeError.cyclicHierarchy
                }
                path.append(item)
                if let parentID = item.parentID {
                    guard let parent = byID[parentID] else {
                        throw NuxieNativeSemanticTreeError.missingAncestor(parentID)
                    }
                    current = parent
                } else {
                    current = nil
                }
            }
            var inherited = current.flatMap { inheritedStates[$0.id] } ?? 0
            var nearestList = current.flatMap { nearestLists[$0.id] }
            for item in path.reversed() {
                if let ownerID = item.collectionID, ownerID != nearestList {
                    throw NuxieNativeSemanticTreeError.invalidCollectionMetadata(item.id)
                }
                if item.role == NuxieNativeSemanticRole.list.rawValue { nearestList = item.id }
                nearestLists[item.id] = nearestList
                inherited |= item.stateFlags & inheritedMask
                inheritedStates[item.id] = inherited
            }
        }
        if case .active(let id) = modalScope {
            guard let modal = byID[id],
                  inheritedStates[id, default: 0] & NuxieNativeSemanticNode.hidden == 0,
                  modal.stateFlags & NuxieNativeSemanticNode.modal != 0,
                  modal.role == NuxieNativeSemanticRole.dialog.rawValue
                    || modal.role == NuxieNativeSemanticRole.alertDialog.rawValue else {
                throw NuxieNativeSemanticTreeError.invalidModalIdentity(id)
            }
        }
        self.modalScope = modalScope
        self.renderRevision = renderRevision
        self.treeVersion = treeVersion
        self.nodes = nodes.map { node in
            var projected = node
            projected.stateFlags |= inheritedStates[node.id] ?? 0
            return projected
        }
    }
}

package enum NuxieNativeSemanticAction: UInt32, Sendable {
    case tap = 0
    case increase = 1
    case decrease = 2
}

/// Identity authorizes a request only against the retained capture in its runtime.
package struct NuxieNativeSemanticCapture: Sendable {
    package let id: UUID
    package let tree: NuxieNativeSemanticTree
    package let fieldsByTextRun: [String: NuxieNativeSemanticNode]

    package init(id: UUID, tree: NuxieNativeSemanticTree, fieldsByTextRun: [String: NuxieNativeSemanticNode]) {
        self.id = id
        self.tree = tree
        let exposed = tree.exposedNodeIDs
        self.fieldsByTextRun = fieldsByTextRun.filter { exposed.contains($0.value.id) }
    }
}

package enum NuxieNativeSemanticRole: UInt32, Sendable {
    case none = 0, button, link, checkbox, switchControl, slider, textField, text, image
    case group, list, listItem, tab, tabList, dialog, alertDialog, radioGroup, radioButton
}

/// Capability bits are separate from the current state of the same control.
package enum NuxieNativeSemanticTrait {
    package static let expandable: UInt32 = 1 << 0
    package static let checkable: UInt32 = 1 << 2
    package static let toggleable: UInt32 = 1 << 3
}
