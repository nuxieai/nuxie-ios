#if canImport(UIKit)
import NuxieRuntime
import UIKit

/// A drawn control forwards exact semantic actions to its owning presentation.
/// The callback reports queue admission; native execution can still reject a stale frame.
@MainActor
final class ExperienceSemanticAccessibilityElement: UIAccessibilityElement {
    typealias Submit = (UUID, UInt32, NuxieNativeSemanticAction) -> Bool

    private var captureID: UUID?
    private var node: NuxieNativeSemanticNode?
    private var submit: Submit?

    func update(
        captureID: UUID,
        node: NuxieNativeSemanticNode,
        frameInContainer: CGRect,
        traits: UIAccessibilityTraits,
        submit: @escaping Submit
    ) {
        self.captureID = captureID
        self.node = node
        self.submit = submit
        accessibilityLabel = node.label
        accessibilityValue = node.value.isEmpty ? nil : node.value
        accessibilityHint = node.hint.isEmpty ? nil : node.hint
        accessibilityFrameInContainerSpace = frameInContainer
        accessibilityTraits = traits
        if node.stateFlags & NuxieNativeSemanticNode.disabled != 0 {
            accessibilityTraits.insert(.notEnabled)
        }
        isAccessibilityElement = node.stateFlags & NuxieNativeSemanticNode.hidden == 0
    }

    func retire() {
        captureID = nil
        node = nil
        submit = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
    }

    override func accessibilityActivate() -> Bool { perform(.tap) }
    override func accessibilityIncrement() { _ = perform(.increase) }
    override func accessibilityDecrement() { _ = perform(.decrease) }

    static func allowsInteraction(in view: UIView) -> Bool {
        var current: UIView? = view
        while let ancestor = current {
            guard ancestor.isUserInteractionEnabled, !ancestor.isHidden, ancestor.alpha > 0.01 else { return false }
            current = ancestor.superview
        }
        return true
    }

    private func perform(_ action: NuxieNativeSemanticAction) -> Bool {
        guard isAccessibilityElement,
              let container = accessibilityContainer as? UIView,
              Self.allowsInteraction(in: container),
              let captureID, let node, let submit,
              node.stateFlags & NuxieNativeSemanticNode.disabled == 0,
              node.actions & (1 << action.rawValue) != 0 else { return false }
        return submit(captureID, node.id, action)
    }
}
#endif
