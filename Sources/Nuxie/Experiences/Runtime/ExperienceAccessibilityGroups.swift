#if canImport(UIKit)
import NuxieRuntime
import UIKit

/// Structural collection containers reuse the actual controls and their identities.
@MainActor
final class ExperienceAccessibilityGroups {
    private var groups: [UInt32: UIAccessibilityElement] = [:]

    func arrange(in view: UIView, nodes: [NuxieNativeSemanticNode],
                 objects: [UInt32: AnyObject], frames: [UInt32: CGRect]) -> [Any] {
        // Nodes are in authored depth-first order. Resolve membership once, even
        // for deep layout wrappers, without recursively walking the hierarchy.
        var hasDescendant: Set<UInt32> = []
        for node in nodes.reversed() where objects[node.id] != nil || hasDescendant.contains(node.id) {
            if let parent = node.parentID { hasDescendant.insert(parent) }
        }
        var next: [UInt32: UIAccessibilityElement] = [:]
        for node in nodes where objects[node.id] != nil && hasDescendant.contains(node.id) {
            guard node.role == NuxieNativeSemanticRole.list.rawValue
                    || node.role == NuxieNativeSemanticRole.listItem.rawValue else { continue }
            let group = groups[node.id] ?? UIAccessibilityElement(accessibilityContainer: view)
            group.isAccessibilityElement = false
            // UIKit has no independent logical item-count field. A semantic
            // group preserves navigation without claiming the exposed count is total.
            group.accessibilityContainerType = .semanticGroup
            next[node.id] = group
        }
        for (id, group) in groups where next[id] == nil { group.accessibilityElements = nil }
        groups = next
        var nearestGroup: [UInt32: UInt32] = [:]
        var children: [UInt32: [Any]] = [:]
        var roots: [Any] = []
        func append(_ object: AnyObject, to parent: UInt32?) {
            if let parent { children[parent, default: []].append(object) }
            else { roots.append(object) }
        }
        func place(_ element: UIAccessibilityElement, frame: CGRect, in parent: UInt32?) {
            if let parent, let group = groups[parent] { element.accessibilityContainer = group }
            else { element.accessibilityContainer = view }
            let origin = parent.flatMap { frames[$0]?.origin } ?? .zero
            element.accessibilityFrameInContainerSpace = frame.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        for node in nodes {
            let enclosing = node.parentID.flatMap { nearestGroup[$0] }
            var parent = enclosing
            if let group = groups[node.id], let frame = frames[node.id] {
                place(group, frame: frame, in: enclosing)
                append(group, to: enclosing)
                parent = node.id
            }
            nearestGroup[node.id] = parent
            guard let object = objects[node.id] else { continue }
            if let element = object as? UIAccessibilityElement, let frame = frames[node.id] {
                place(element, frame: frame, in: parent)
            }
            // Native editors keep their real UIView parent. UIKit enumerates
            // them through this group without replacing or duplicating them.
            append(object, to: parent)
        }
        for (id, group) in groups { group.accessibilityElements = children[id] ?? [] }
        return roots
    }

    func clear() {
        for group in groups.values { group.accessibilityElements = nil }
        groups.removeAll()
    }
}
#endif
