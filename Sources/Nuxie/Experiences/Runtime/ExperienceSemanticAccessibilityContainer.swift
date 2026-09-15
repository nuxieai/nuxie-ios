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

    init(view: UIView) {
        self.view = view
    }

    func update(
        capture: NuxieNativeSemanticCapture,
        nativeControls: [UInt32: UIView],
        project: (NuxieNativeSemanticNode) -> Projection?,
        submit: @escaping ExperienceSemanticAccessibilityElement.Submit
    ) {
        guard let view else { clear(); return }
        var next: [UInt32: ExperienceSemanticAccessibilityElement] = [:]
        var ordered: [Any] = []
        for node in capture.tree.visibleReadingOrder {
            guard let projection = project(node) else { continue }
            if node.role == NuxieNativeSemanticRole.textField.rawValue {
                // An editable semantic node is represented exclusively by its real control.
                if let control = nativeControls[node.id] { ordered.append(control) }
                continue
            }
            let element = elements[node.id]
                ?? ExperienceSemanticAccessibilityElement(accessibilityContainer: view)
            element.update(captureID: capture.id, node: node,
                frameInContainer: projection.frame, traits: projection.traits, submit: submit)
            next[node.id] = element
            ordered.append(element)
        }
        for (id, element) in elements where next[id] == nil { element.retire() }
        elements = next
        view.isAccessibilityElement = false
        view.accessibilityElements = ordered
    }

    func clear() {
        for element in elements.values { element.retire() }
        elements.removeAll()
        view?.accessibilityElements = []
    }
}
#endif
