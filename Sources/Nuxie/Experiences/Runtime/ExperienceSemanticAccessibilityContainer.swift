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

    private let focusedElement: () -> AnyObject?
    private let moveFocus: (AnyObject) -> Void
    private var objects: [UInt32: AnyObject] = [:]
    private var order: [UInt32] = []
    private var preferredFocusID: UInt32?
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
            let id = rememberFocus()
            withdrawnFocus = id.flatMap { objects[$0] }
            focusIntent = id == nil ? .none : .restore
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
        var next: [UInt32: ExperienceSemanticAccessibilityElement] = [:]
        var ordered: [Any] = []
        var nextObjects: [UInt32: AnyObject] = [:]
        var nextOrder: [UInt32] = []
        for node in capture.tree.visibleReadingOrder {
            guard let projection = project(node) else { continue }
            if node.role == NuxieNativeSemanticRole.textField.rawValue {
                // An editable semantic node is represented exclusively by its real control.
                if let control = nativeControls[node.id] {
                    ordered.append(control)
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
            ordered.append(element)
            nextObjects[node.id] = element
            nextOrder.append(node.id)
        }
        for (id, element) in elements where next[id] == nil { element.retire() }
        elements = next
        view.isAccessibilityElement = false
        view.accessibilityElements = ordered
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
        removeElements()
    }

    private func removeElements() {
        for element in elements.values { element.retire() }
        elements.removeAll()
        objects.removeAll()
        order.removeAll()
        view?.accessibilityElements = []
    }
}
#endif
