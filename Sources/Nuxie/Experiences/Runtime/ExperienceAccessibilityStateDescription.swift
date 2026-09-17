import Foundation
import NuxieRuntime

/// Platform-owned state words supplement authored values without changing runtime meaning.
enum ExperienceAccessibilityStateDescription {
    #if SWIFT_PACKAGE
    static let resourceBundle = Bundle.module
    #else
    static let resourceBundle = Bundle(for: ResourceToken.self)
    #endif

    /// Native editors retain their own value and selection representation. State
    /// words belong in their spoken label; input labels retain the authored name.
    static func fieldLabel(for node: NuxieNativeSemanticNode, bundle: Bundle = resourceBundle) -> String {
        ([node.label] + fieldStates(for: node, bundle: bundle))
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func fieldStates(for node: NuxieNativeSemanticNode, bundle: Bundle) -> [String] {
        [(NuxieNativeSemanticNode.required, "required"), (NuxieNativeSemanticNode.readOnly, "readOnly")]
            .compactMap { flag, key in
                node.stateFlags & flag == 0 ? nil
                    : bundle.localizedString(forKey: key, value: nil, table: "NuxieAccessibility")
            }
    }

    static func isToggle(_ node: NuxieNativeSemanticNode) -> Bool {
        let role = NuxieNativeSemanticRole(rawValue: node.role)
        return role == .checkbox || role == .switchControl || role == .radioButton
            || node.traitFlags & (NuxieNativeSemanticTrait.checkable | NuxieNativeSemanticTrait.toggleable) != 0
    }

    static func value(
        for node: NuxieNativeSemanticNode,
        supportsExpandedStatus: Bool,
        bundle: Bundle = resourceBundle
    ) -> String? {
        func text(_ key: String) -> String {
            bundle.localizedString(forKey: key, value: nil, table: "NuxieAccessibility")
        }
        let toggle = isToggle(node)
        let obscured = node.stateFlags & NuxieNativeSemanticNode.obscured != 0
        let mixed = node.stateFlags & NuxieNativeSemanticNode.mixed != 0
        let on = node.stateFlags & (NuxieNativeSemanticNode.checked | NuxieNativeSemanticNode.toggled) != 0
        var states: [String] = []
        if toggle && mixed && !obscured { states.append(text("mixed")) }
        if !supportsExpandedStatus && node.traitFlags & NuxieNativeSemanticTrait.expandable != 0 {
            states.append(text(node.stateFlags & NuxieNativeSemanticNode.expanded != 0 ? "expanded" : "collapsed"))
        }
        states.append(contentsOf: fieldStates(for: node, bundle: bundle))
        var value = obscured ? "" : node.value
        if value.isEmpty && toggle && !mixed && !obscured {
            // Preserve UIKit's binary toggle value when it stands alone. A compound
            // value uses localized words so VoiceOver does not read a bare digit.
            value = states.isEmpty ? (on ? "1" : "0") : text(on ? "on" : "off")
        }
        let parts = ([value] + states).filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private final class ResourceToken {}
