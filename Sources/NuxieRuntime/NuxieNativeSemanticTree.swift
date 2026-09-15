import Foundation

/// Portable semantic ABI values. Platform views consume copied values, never native handles.
package struct NuxieNativeSemanticNode: Equatable, Sendable {
    package static let selected: UInt32 = 1 << 1
    package static let disabled: UInt32 = 1 << 6
    package static let readOnly: UInt32 = 1 << 10
    package static let hidden: UInt32 = 1 << 8
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
        hint: String
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
    }
}

package enum NuxieNativeSemanticTreeError: Error, Equatable {
    case tooManyNodes
    case duplicateIdentity(UInt32)
    case missingAncestor(UInt32)
    case cyclicHierarchy
}

/// One copied presented revision. Both native editors and drawn controls receive
/// effective disabled/hidden state; the runtime separately authorizes exact actions.
package struct NuxieNativeSemanticTree: Sendable {
    package let renderRevision: UInt64
    package let treeVersion: UInt64
    package let nodes: [NuxieNativeSemanticNode]

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
        nodes: [NuxieNativeSemanticNode]
    ) throws {
        guard nodes.count <= 16_384 else { throw NuxieNativeSemanticTreeError.tooManyNodes }
        var byID: [UInt32: NuxieNativeSemanticNode] = [:]
        for node in nodes {
            guard byID.updateValue(node, forKey: node.id) == nil else {
                throw NuxieNativeSemanticTreeError.duplicateIdentity(node.id)
            }
        }
        let inheritedMask = NuxieNativeSemanticNode.disabled | NuxieNativeSemanticNode.hidden
        var inheritedStates: [UInt32: UInt32] = [:]
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
            for item in path.reversed() {
                inherited |= item.stateFlags & inheritedMask
                inheritedStates[item.id] = inherited
            }
        }
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
        self.fieldsByTextRun = fieldsByTextRun
    }
}

package enum NuxieNativeSemanticRole: UInt32, Sendable {
    case none = 0, button, link, checkbox, switchControl, slider, textField, text, image
    case group, list, listItem, tab, tabList, dialog, alertDialog, radioGroup, radioButton
}
