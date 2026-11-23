#if canImport(UIKit)
import UIKit

/// A drawn control forwards exact semantic actions to its owning presentation.
/// The callback reports queue admission; native execution can still reject a stale frame.
///
/// What the element says beyond the node's own words, and which actions an
/// activation may ask for, are the screen's: they arrive in its projection
/// ([`ExperienceSemanticAccessibilityContainer.Projection`]).
@MainActor
package final class ExperienceSemanticAccessibilityElement: UIAccessibilityElement {
    package typealias Submit = (UUID, UInt32, NuxieNativeSemanticAction) -> Bool

    package private(set) var captureID: UUID?
    private var node: NuxieNativeSemanticNode?
    private var actions: UInt32 = 0
    private var submit: Submit?

    package func update(
        captureID: UUID,
        node: NuxieNativeSemanticNode,
        projection: ExperienceSemanticAccessibilityContainer.Projection,
        submit: @escaping Submit
    ) {
        self.captureID = captureID
        self.node = node
        self.actions = projection.actions
        self.submit = submit
        accessibilityLabel = node.label
        accessibilityValue = projection.value
        accessibilityHint = node.hint.isEmpty ? nil : node.hint
        accessibilityFrameInContainerSpace = projection.frame
        accessibilityTraits = projection.traits
        if node.stateFlags & NuxieNativeSemanticNode.selected != 0 {
            accessibilityTraits.insert(.selected)
        }
        if #available(iOS 18.0, *) {
            accessibilityExpandedStatus = node.traitFlags & NuxieNativeSemanticTrait.expandable == 0
                ? .unsupported : (node.stateFlags & NuxieNativeSemanticNode.expanded != 0 ? .expanded : .collapsed)
        }
        if node.stateFlags & NuxieNativeSemanticNode.disabled != 0 {
            accessibilityTraits.insert(.notEnabled)
        }
        isAccessibilityElement = node.stateFlags & NuxieNativeSemanticNode.hidden == 0
    }

    package func retire() {
        captureID = nil
        node = nil
        actions = 0
        submit = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
        if #available(iOS 18.0, *) { accessibilityExpandedStatus = .unsupported }
    }

    override package func accessibilityActivate() -> Bool { perform(.tap) }
    override package func accessibilityIncrement() { _ = perform(.increase) }
    override package func accessibilityDecrement() { _ = perform(.decrease) }

    package static func allowsInteraction(in view: UIView) -> Bool {
        var current: UIView? = view
        while let ancestor = current {
            guard ancestor.isUserInteractionEnabled, !ancestor.isHidden, ancestor.alpha > 0.01 else { return false }
            current = ancestor.superview
        }
        return true
    }

    /// Whether a screen reader's action on an element of `view` may reach
    /// its Screen: the view takes interaction, and no view from it up hides
    /// its accessibility elements. A Screen under another presentation is
    /// hidden that way, so an element kept from before it was covered takes
    /// no action, whichever action it is asked for.
    package static func allowsAccessibilityAction(in view: UIView) -> Bool {
        guard allowsInteraction(in: view) else { return false }
        var current: UIView? = view
        while let ancestor = current {
            if ancestor.accessibilityElementsHidden { return false }
            current = ancestor.superview
        }
        return true
    }

    private func perform(_ action: NuxieNativeSemanticAction) -> Bool {
        guard isAccessibilityElement,
              let container = accessibilityContainer as? UIView,
              Self.allowsAccessibilityAction(in: container),
              let captureID, let node, let submit,
              node.stateFlags & NuxieNativeSemanticNode.disabled == 0,
              actions & (1 << action.rawValue) != 0 else { return false }
        return submit(captureID, node.id, action)
    }
}
#endif
