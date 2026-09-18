#if canImport(UIKit)
import NuxieRuntime
import UIKit

/// Owns stable drawn elements and interleaves actual editors in authored order.
/// The screen supplies committed geometry and role projection for each node.
@MainActor
final class ExperienceSemanticAccessibilityContainer {
    struct Projection {
        let frame: CGRect
        let traits: UIAccessibilityTraits
    }

    private weak var view: UIView?
    private var elements: [UInt32: ExperienceSemanticAccessibilityElement] = [:]
    private let groups = ExperienceAccessibilityGroups()

    private let focusedElement: () -> AnyObject?
    private let moveFocus: (AnyObject) -> Void
    private var objects: [UInt32: AnyObject] = [:]
    private var order: [UInt32] = []
    private var preferredFocusID: UInt32?
    private struct ModalFrame {
        let id: UInt32
        let returnFocusID: UInt32?
    }
    private struct ExcludedControl {
        weak var view: UIView?
        let wasHidden: Bool
    }
    private var modalFrames: [ModalFrame] = []
    private var excludedControls: [ObjectIdentifier: ExcludedControl] = [:]
    private var isActive = false
    private enum FocusIntent { case initial, restore, navigation, none }
    private var focusIntent: FocusIntent = .initial
    private weak var withdrawnFocus: AnyObject?

    init(view: UIView,
         focusedElement: @escaping () -> AnyObject? = { UIAccessibility.focusedElement(using: nil) as AnyObject? },
         moveFocus: @escaping (AnyObject) -> Void = { UIAccessibility.post(notification: .layoutChanged, argument: $0) }) {
        self.view = view
        self.focusedElement = focusedElement
        self.moveFocus = moveFocus
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if !active {
            // Activation may be withdrawn before a new frame exposes targets.
            // Keep the pending handoff until there is a presented tree to inspect.
            if !objects.isEmpty {
                let id = rememberFocus()
                withdrawnFocus = id.flatMap { objects[$0] }
                focusIntent = id == nil ? .none : .restore
            }
            removeElements()
        }
        isActive = active
    }

    /// Navigation is an intentional handoff; temporary visibility changes only
    /// restore focus that this container actually owned.
    func requestFocusOnNextPresentation() {
        focusIntent = .navigation
    }

    @discardableResult
    private func rememberFocus() -> UInt32? {
        guard let focused = focusedElement(),
              let id = objects.first(where: { $0.value === focused })?.key else { return nil }
        preferredFocusID = id
        return id
    }

    func update(
        capture: NuxieNativeSemanticCapture,
        nativeControls: [UInt32: UIView],
        project: (NuxieNativeSemanticNode) -> Projection?,
        submit: @escaping ExperienceSemanticAccessibilityElement.Submit
    ) {
        guard let view else { clear(); return }
        guard isActive else { return }
        let focusedID = rememberFocus()
        let focusedObject = focusedID.flatMap { objects[$0] }
        let oldPosition = focusedID.flatMap { order.firstIndex(of: $0) }
        let scope = modalScope(capture.tree)
        let modalChanged = modalFrames.map(\.id) != scope.path
        let currentFocus = focusedElement()
        let mayMoveModalFocus = focusedID != nil || currentFocus == nil
            || currentFocus === withdrawnFocus || focusIntent == .initial || focusIntent == .navigation
        let pendingReturnID = focusIntent == .restore
            && (currentFocus == nil || currentFocus === withdrawnFocus) ? preferredFocusID : nil
        var modalReturnID: UInt32?
        if modalChanged {
            let common = zip(modalFrames.map(\.id), scope.path).prefix { $0 == $1 }.count
            let replacingModal = common < modalFrames.count
            if replacingModal { modalReturnID = modalFrames[common].returnFocusID }
            let returnFocusID = replacingModal ? modalReturnID : focusedID ?? pendingReturnID
            modalFrames = Array(modalFrames.prefix(common))
            for id in scope.path.dropFirst(common) {
                modalFrames.append(ModalFrame(id: id,
                    returnFocusID: modalFrames.count == common ? returnFocusID : nil))
            }
            // Entering a new dialog starts at its first represented node.
            if common < scope.path.count { modalReturnID = nil }
        }
        updateExcludedControls(nativeControls, allowedIDs: Set(scope.nodes.map(\.id)))
        var next: [UInt32: ExperienceSemanticAccessibilityElement] = [:]
        var frames: [UInt32: CGRect] = [:]
        var nextObjects: [UInt32: AnyObject] = [:]
        var nextOrder: [UInt32] = []
        for node in scope.nodes {
            guard let projection = project(node) else { continue }
            frames[node.id] = projection.frame
            if node.role == NuxieNativeSemanticRole.textField.rawValue {
                // An editable semantic node is represented exclusively by its real control.
                if let control = nativeControls[node.id] {
                    nextObjects[node.id] = control
                    nextOrder.append(node.id)
                }
                continue
            }
            let element = elements[node.id]
                ?? ExperienceSemanticAccessibilityElement(accessibilityContainer: view)
            element.update(captureID: capture.id, node: node,
                frameInContainer: projection.frame, traits: projection.traits, submit: submit)
            next[node.id] = element
            nextObjects[node.id] = element
            nextOrder.append(node.id)
        }
        for (id, element) in elements where next[id] == nil { element.retire() }
        elements = next
        view.isAccessibilityElement = false
        view.accessibilityElements = groups.arrange(in: view, nodes: scope.nodes, objects: nextObjects, frames: frames)
        objects = nextObjects
        order = nextOrder
        if let focusedID, objects[focusedID] !== focusedObject {
            focusIntent = .restore
            withdrawnFocus = focusedObject
            if objects[focusedID] != nil {
                preferredFocusID = focusedID
            } else if !order.isEmpty {
                preferredFocusID = order[min(oldPosition ?? 0, order.count - 1)]
            }
        }
        if focusIntent == .restore, let focused = focusedElement(), focused !== withdrawnFocus {
            // A user may have focused a native shell/recovery action while the
            // scene was unavailable. Do not steal that focus on restoration.
            focusIntent = .none
        }
        if modalChanged, mayMoveModalFocus {
            preferredFocusID = modalReturnID
            focusIntent = .navigation
        }
        guard focusIntent != .none, ExperienceSemanticAccessibilityElement.allowsInteraction(in: view),
              let targetID = preferredFocusID.flatMap({ objects[$0] == nil ? nil : $0 }) ?? order.first,
              let target = objects[targetID] else { return }
        focusIntent = .none
        withdrawnFocus = nil
        preferredFocusID = targetID
        moveFocus(target)
    }

    func clear() {
        isActive = false
        focusIntent = .initial
        withdrawnFocus = nil
        preferredFocusID = nil
        modalFrames.removeAll()
        removeElements()
    }

    /// Runtime selection follows paint order; traversal within its subtree keeps
    /// authored reading order. Preserve return focus while resolution is withheld.
    private func modalScope(_ tree: NuxieNativeSemanticTree)
        -> (nodes: [NuxieNativeSemanticNode], path: [UInt32]) {
        let ordered = tree.visibleReadingOrder
        let activeID: UInt32
        switch tree.modalScope {
        case .none: return (ordered, [])
        case .unresolved: return ([], modalFrames.map(\.id))
        case .active(let id): activeID = id
        }
        let isModal: (NuxieNativeSemanticNode) -> Bool = {
            $0.stateFlags & NuxieNativeSemanticNode.modal != 0
                && ($0.role == NuxieNativeSemanticRole.dialog.rawValue
                    || $0.role == NuxieNativeSemanticRole.alertDialog.rawValue)
        }
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        guard let modal = byID[activeID] else { return ([], modalFrames.map(\.id)) }
        var path: [UInt32] = []
        var current: NuxieNativeSemanticNode? = modal
        while let node = current {
            if isModal(node) { path.append(node.id) }
            current = node.parentID.flatMap { byID[$0] }
        }
        var descendants: Set<UInt32> = [modal.id]
        let nodes = ordered.filter { node in
            if node.parentID.map({ descendants.contains($0) }) == true { descendants.insert(node.id) }
            return descendants.contains(node.id)
        }
        return (nodes, path.reversed())
    }

    private func updateExcludedControls(_ controls: [UInt32: UIView], allowedIDs: Set<UInt32>) {
        let excluded = Dictionary(uniqueKeysWithValues: controls.filter { !allowedIDs.contains($0.key) }
            .map { (ObjectIdentifier($0.value), $0.value) })
        for (id, saved) in excludedControls where excluded[id] == nil {
            saved.view?.accessibilityElementsHidden = saved.wasHidden
            excludedControls.removeValue(forKey: id)
        }
        for (id, control) in excluded {
            if excludedControls[id] == nil {
                excludedControls[id] = ExcludedControl(view: control, wasHidden: control.accessibilityElementsHidden)
            }
            control.accessibilityElementsHidden = true
        }
    }

    private func removeElements() {
        updateExcludedControls([:], allowedIDs: [])
        for element in elements.values { element.retire() }
        elements.removeAll()
        groups.clear()
        objects.removeAll()
        order.removeAll()
        view?.accessibilityElements = []
    }
}
#endif
