#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// How a machine Screen reads a radio and its radio group from the engine's
/// semantic snapshot: hand-built nodes with the values the compiler writes,
/// each shown as one accessibility element the way the Screen shows every
/// node of a frame.
///
/// The values: a radio is role 17 with the checkable and enablable traits
/// (36); its state holds the engine's check state in two bits from bit 2,
/// unchecked (0), checked (4) or mixed (8), and disabled at bit 6 (64). A
/// radio group is role 16, named by its label.
final class MachineRadioReadingTests: XCTestCase {
    private static let surface = CGRect(x: 0, y: 0, width: 390, height: 844)

    /// 1. A radio is read as a button, selected while its check state is
    ///    checked: state 4 is selected, state 0 is not, and state 68
    ///    (checked and disabled) is selected and not enabled. A mixed radio
    ///    is not selected.
    @MainActor
    func testACheckedRadioIsASelectedButtonAndOneNotCheckedIsNot() throws {
        let checked = try read(radio(state: 4))
        XCTAssertTrue(checked.contains(.button), "a radio is a button")
        XCTAssertTrue(checked.contains(.selected), "checked is selected")
        XCTAssertFalse(checked.contains(.notEnabled))

        let unchecked = try read(radio(state: 0))
        XCTAssertTrue(unchecked.contains(.button))
        XCTAssertFalse(unchecked.contains(.selected), "not checked is not selected")

        let disabled = try read(radio(state: 68))
        XCTAssertTrue(disabled.contains(.button))
        XCTAssertTrue(disabled.contains(.selected), "checked and disabled is selected")
        XCTAssertTrue(disabled.contains(.notEnabled), "and not enabled")

        let mixed = try read(radio(state: 8))
        XCTAssertFalse(mixed.contains(.selected), "mixed is not selected")
    }

    /// 2. A radio that stops being checked stops being selected: the same
    ///    element, read anew from the next snapshot, loses the trait.
    @MainActor
    func testARadioReadAgainAfterItIsUncheckedIsNotSelected() throws {
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: UIView())
        try show(radio(state: 4), on: element)
        XCTAssertTrue(element.accessibilityTraits.contains(.selected))
        try show(radio(state: 0), on: element)
        XCTAssertFalse(element.accessibilityTraits.contains(.selected), "the trait goes with the check")
    }

    /// 3. A radio group with a label is an element of its own, named by its
    ///    label, with no trait of its own, read before the radios it holds;
    ///    one with no label is no element, and its radios are read alone.
    @MainActor
    func testARadioGroupIsReadByItsLabelBeforeItsRadios() throws {
        let group = node(id: 1, parent: nil, role: 16, label: "Plan", state: 0, traits: 0,
                         bounds: CGRect(x: 24, y: 248, width: 342, height: 156))
        let yearly = node(id: 2, parent: 1, index: 0, role: 17, label: "Yearly $59.99", state: 4, traits: 36,
                          bounds: CGRect(x: 24, y: 248, width: 342, height: 72))
        let monthly = node(id: 3, parent: 1, index: 1, role: 17, label: "Monthly $9.99", state: 0, traits: 36,
                           bounds: CGRect(x: 24, y: 332, width: 342, height: 72))
        let tree = try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1, nodes: [monthly, group, yearly])
        let read = tree.visibleReadingOrder.compactMap { node in
            NuxieMachineScreenViewController.projection(for: node, on: Self.surface).map { (node.label, $0.traits) }
        }
        XCTAssertEqual(read.map(\.0), ["Plan", "Yearly $59.99", "Monthly $9.99"])
        XCTAssertEqual(read.first?.1, [], "a group has no trait of its own")
        XCTAssertEqual(read.map { $0.1.contains(.selected) }, [false, true, false])

        let unlabeled = node(id: 1, parent: nil, role: 16, label: "", state: 0, traits: 0,
                             bounds: CGRect(x: 24, y: 248, width: 342, height: 156))
        XCTAssertNil(NuxieMachineScreenViewController.projection(for: unlabeled, on: Self.surface),
                     "a radio group with no label is no element")
    }

    // MARK: Nodes

    private func radio(state: UInt32) -> NuxieNativeSemanticNode {
        node(id: 2, parent: nil, role: 17, label: "Yearly $59.99", state: state, traits: 36,
             bounds: CGRect(x: 24, y: 248, width: 342, height: 72))
    }

    private func node(
        id: UInt32, parent: UInt32?, index: UInt32 = 0, role: UInt32, label: String,
        state: UInt32, traits: UInt32, bounds: CGRect
    ) -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(
            id: id, parentID: parent, siblingIndex: index, role: role, stateFlags: state, traitFlags: traits,
            headingLevel: 0, actions: 0, bounds: bounds, label: label, value: "", hint: "")
    }

    /// The traits a screen reader is given for `node`, shown as the Screen
    /// shows it.
    @MainActor
    private func read(_ node: NuxieNativeSemanticNode) throws -> UIAccessibilityTraits {
        let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: UIView())
        try show(node, on: element)
        XCTAssertEqual(element.accessibilityLabel, node.label)
        return element.accessibilityTraits
    }

    @MainActor
    private func show(_ node: NuxieNativeSemanticNode, on element: ExperienceSemanticAccessibilityElement) throws {
        let projection = try XCTUnwrap(
            NuxieMachineScreenViewController.projection(for: node, on: Self.surface), "the node is an element")
        element.update(captureID: UUID(), node: node, projection: projection, submit: { _, _, _ in false })
    }
}
#endif
