#if canImport(UIKit)
import UIKit
import XCTest
@testable import Nuxie
import NuxieRuntime

@MainActor
final class ExperienceSemanticAccessibilityElementTests: XCTestCase {
    func testActionsUseLatestCaptureAndRetirementRejectsRetainedElement() {
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        var requests: [(UUID, UInt32, NuxieNativeSemanticAction)] = []
        let first = UUID()
        update(element, captureID: first, node: node(actions: 1), frame: .zero,
            traits: .button) { requests.append(($0, $1, $2)); return true }
        XCTAssertTrue(element.accessibilityActivate())
        element.accessibilityIncrement()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, first)
        XCTAssertEqual(requests.first?.1, UInt32.max)
        let second = UUID()
        update(element, captureID: second, node: node(actions: 6), frame: .zero,
            traits: .adjustable) { requests.append(($0, $1, $2)); return true }
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        element.accessibilityDecrement()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].0, second)
        XCTAssertEqual(requests[1].2, .increase)
        XCTAssertEqual(requests[2].2, .decrease)
        element.retire()
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(element.isAccessibilityElement)
        XCTAssertNil(element.accessibilityLabel)
    }

    func testDisabledControlsRejectActionsAndRefreshClearsDisabledTrait() {
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        var calls = 0
        let submit: ExperienceSemanticAccessibilityElement.Submit = { _, _, _ in calls += 1; return false }
        update(element, captureID: UUID(), node: node(actions: 7, flags: NuxieNativeSemanticNode.disabled),
            frame: CGRect(x: 2, y: 3, width: 4, height: 5), traits: .button, submit: submit)
        XCTAssertTrue(element.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(element.accessibilityLabel, "Prénom 👋")
        XCTAssertEqual(element.accessibilityFrameInContainerSpace, CGRect(x: 2, y: 3, width: 4, height: 5))
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        element.accessibilityDecrement()
        XCTAssertEqual(calls, 0)
        update(element, captureID: UUID(), node: node(actions: 1), frame: .zero,
            traits: .button, submit: submit)
        XCTAssertFalse(element.accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(element.accessibilityActivate(), "Forward queue rejection to UIKit")
        XCTAssertEqual(calls, 1)
    }

    func testAncestorInteractionAndVisibilityWithdrawalRejectRetainedElement() {
        let parent = UIView()
        let surface = UIView()
        parent.addSubview(surface)
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: surface)
        var count = 0
        update(element, captureID: UUID(), node: node(actions: 1), frame: .zero,
            traits: .button) { _, _, _ in count += 1; return true }
        XCTAssertTrue(element.accessibilityActivate())
        parent.isUserInteractionEnabled = false
        XCTAssertFalse(element.accessibilityActivate())
        parent.isUserInteractionEnabled = true
        parent.isHidden = true
        XCTAssertFalse(element.accessibilityActivate())
        parent.isHidden = false
        parent.alpha = 0
        XCTAssertFalse(element.accessibilityActivate())
        parent.alpha = 1
        XCTAssertTrue(element.accessibilityActivate())
        XCTAssertEqual(count, 2)
    }

    func testHiddenControlCannotActivate() {
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        update(element, captureID: UUID(), node: node(actions: 7, flags: NuxieNativeSemanticNode.hidden),
            frame: .zero, traits: .button) { _, _, _ in
                XCTFail("Hidden controls cannot submit actions")
                return true
            }
        XCTAssertFalse(element.isAccessibilityElement)
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        element.accessibilityDecrement()
    }

    func testToggleStateRefreshesWithoutChangingAuthoredValueOrInventingActions() {
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        for role in [NuxieNativeSemanticRole.checkbox, .switchControl, .radioButton] {
            for state in [NuxieNativeSemanticNode.checked, NuxieNativeSemanticNode.toggled] {
                update(element, captureID: UUID(), node: node(actions: 0, flags: state, role: role.rawValue, value: "Valeur publiée"),
                    frame: .zero, traits: .button) { _, _, _ in XCTFail("No authored action"); return true }
                if #available(iOS 17.0, *) { XCTAssertTrue(element.accessibilityTraits.contains(.toggleButton)) }
                XCTAssertFalse(element.accessibilityTraits.contains(.selected), "On/off is not selection")
                XCTAssertEqual(element.accessibilityValue, "Valeur publiée")
                XCTAssertFalse(element.accessibilityActivate())
                update(element, captureID: UUID(), node: node(actions: 0, role: role.rawValue),
                    frame: .zero, traits: .button) { _, _, _ in false }
                XCTAssertFalse(element.accessibilityTraits.contains(.selected))
                XCTAssertEqual(element.accessibilityValue, "0")
            }
        }
        update(element, captureID: UUID(), node: node(actions: 0, flags: NuxieNativeSemanticNode.toggled,
            semanticTraits: NuxieNativeSemanticTrait.toggleable), frame: .zero,
            traits: .button) { _, _, _ in false }
        XCTAssertEqual(element.accessibilityValue, "1", "Authored toggle capability also applies to button roles")
        update(element, captureID: UUID(), node: node(actions: 0), frame: .zero,
            traits: .button) { _, _, _ in false }
        if #available(iOS 17.0, *) { XCTAssertFalse(element.accessibilityTraits.contains(.toggleButton)) }
        XCTAssertFalse(element.accessibilityTraits.contains(.selected))
    }

    func testToggleFallbackDescribesMixedAndDoesNotExposeObscuredValues() {
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        for flag in [NuxieNativeSemanticNode.mixed, NuxieNativeSemanticNode.obscured] {
            update(element, captureID: UUID(), node: node(actions: 1,
                flags: flag | NuxieNativeSemanticNode.toggled, role: NuxieNativeSemanticRole.switchControl.rawValue),
                frame: .zero, traits: .button) { _, _, _ in false }
            XCTAssertEqual(element.accessibilityValue, flag == NuxieNativeSemanticNode.mixed ? "Mixed" : nil)
        }
        update(element, captureID: UUID(), node: node(actions: 1, flags: NuxieNativeSemanticNode.selected),
            frame: .zero, traits: .button) { _, _, _ in false }
        XCTAssertTrue(element.accessibilityTraits.contains(.selected))
    }

    func testExpandableStatusDistinguishesCollapsedFromUnsupportedAndRetires() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native expanded status requires iOS 18") }
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        let submit: ExperienceSemanticAccessibilityElement.Submit = { _, _, _ in false }
        update(element, captureID: UUID(), node: node(actions: 1, flags: NuxieNativeSemanticNode.expanded,
            semanticTraits: NuxieNativeSemanticTrait.expandable), frame: .zero, traits: .button, submit: submit)
        XCTAssertEqual(element.accessibilityExpandedStatus, .expanded)
        update(element, captureID: UUID(), node: node(actions: 1,
            semanticTraits: NuxieNativeSemanticTrait.expandable), frame: .zero, traits: .button, submit: submit)
        XCTAssertEqual(element.accessibilityExpandedStatus, .collapsed)
        update(element, captureID: UUID(), node: node(actions: 1, flags: NuxieNativeSemanticNode.expanded),
            frame: .zero, traits: .button, submit: submit)
        XCTAssertEqual(element.accessibilityExpandedStatus, .unsupported, "A state bit cannot invent capability")
        element.retire()
        XCTAssertEqual(element.accessibilityExpandedStatus, .unsupported)
        XCTAssertEqual(element.accessibilityTraits, [])
    }

    func testSharedControlStateVectors() throws {
        struct Vector: Decodable {
            let id: String
            let role: UInt32
            let traits: UInt32
            let state: UInt32
            let value: String
            let checkable: Bool
            let expandable: Bool
            let expanded: Bool
            let iosValue: String?
            let iosValueBefore18: String?
        }
        struct Suite: Decodable { let schemaVersion: Int; let cases: [Vector] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/accessibility/control-state.json")))
        XCTAssertEqual(suite.schemaVersion, 1)
        let container = UIView()
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: container)
        for vector in suite.cases {
            update(element, captureID: UUID(), node: node(actions: 1, flags: vector.state,
                role: vector.role, semanticTraits: vector.traits, value: vector.value),
                frame: .zero, traits: .button) { _, _, _ in false }
            let expectedValue: String?
            if #available(iOS 18.0, *) { expectedValue = vector.iosValue } else { expectedValue = vector.iosValueBefore18 }
            XCTAssertEqual(element.accessibilityValue, expectedValue, vector.id)
            XCTAssertEqual(ExperienceAccessibilityStateDescription.value(
                for: node(actions: 1, flags: vector.state, role: vector.role,
                          semanticTraits: vector.traits, value: vector.value), supportsExpandedStatus: false),
                vector.iosValueBefore18, vector.id)
            if #available(iOS 17.0, *) {
                XCTAssertEqual(element.accessibilityTraits.contains(.toggleButton), vector.checkable, vector.id)
            }
            if #available(iOS 18.0, *) {
                XCTAssertEqual(element.accessibilityExpandedStatus, !vector.expandable ? .unsupported
                    : (vector.expanded ? .expanded : .collapsed), vector.id)
            }
        }
    }

    func testStateWordsResolveFromPackagedFrenchLocalization() throws {
        let path = try XCTUnwrap(ExperienceAccessibilityStateDescription.resourceBundle.path(forResource: "fr", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let value = ExperienceAccessibilityStateDescription.value(
            for: node(actions: 1, flags: NuxieNativeSemanticNode.mixed | NuxieNativeSemanticNode.required,
                      semanticTraits: NuxieNativeSemanticTrait.checkable),
            supportsExpandedStatus: false, bundle: bundle)
        XCTAssertEqual(value, "Mixte, Obligatoire")
    }

    /// The element as an Experience Screen shows `node`.
    private func update(
        _ element: ExperienceSemanticAccessibilityElement, captureID: UUID, node: NuxieNativeSemanticNode,
        frame: CGRect, traits: UIAccessibilityTraits, submit: @escaping ExperienceSemanticAccessibilityElement.Submit
    ) {
        element.update(captureID: captureID, node: node, projection: ExperienceAccessibilityStateDescription.projection(
            for: node, frame: frame, traits: traits), submit: submit)
    }

    private func node(actions: UInt32, flags: UInt32 = 0, role: UInt32 = 1,
                      semanticTraits: UInt32 = 0, value: String = "") -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(id: .max, parentID: nil, siblingIndex: 0, role: role,
            stateFlags: flags, traitFlags: semanticTraits, headingLevel: 0, actions: actions,
            bounds: .zero, label: "Prénom 👋", value: value, hint: "Activate")
    }
}
#endif
