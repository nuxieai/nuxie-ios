#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest
@testable import Nuxie
import NuxieRuntime

/// Platform oracle for nesting virtual collection containers in UIKit.
@MainActor
final class UIKitAccessibilityContainerContractTests: XCTestCase {
    func testExperienceGroupsPreserveActionsEditorsGeometryAndFocusAcrossUpdates() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let host = controller.view!
        let field = UITextField(frame: CGRect(x: 20, y: 60, width: 100, height: 30))
        host.addSubview(field)
        var focused: AnyObject?
        var actions: [UInt32] = []
        let container = ExperienceSemanticAccessibilityContainer(view: host,
            focusedElement: { focused }, moveFocus: { focused = $0 })
        container.setActive(true)
        func node(_ id: UInt32, _ parent: UInt32?, _ role: NuxieNativeSemanticRole, _ frame: CGRect, order: UInt32? = nil) -> NuxieNativeSemanticNode {
            NuxieNativeSemanticNode(id: id, parentID: parent, siblingIndex: order ?? id,
                role: role.rawValue, stateFlags: 0, traitFlags: 0, headingLevel: 0,
                actions: 1, bounds: frame, label: "Node \(id)", value: "", hint: "")
        }
        let list = node(1, nil, .list, CGRect(x: 10, y: 15, width: 200, height: 300))
        let item = node(2, 1, .listItem, CGRect(x: 15, y: 22, width: 150, height: 100))
        let button = node(3, 2, .button, CGRect(x: 17, y: 25, width: 40, height: 20))
        let editor = node(4, 2, .textField, field.frame)
        func publish(_ nodes: [NuxieNativeSemanticNode]) throws {
            let tree = try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1, nodes: nodes)
            container.update(capture: .init(id: UUID(), tree: tree, fieldsByTextRun: [:]),
                nativeControls: [4: field], project: { .init(frame: $0.bounds, traits: .button) }) { _, id, _ in
                actions.append(id)
                return true
            }
        }
        try publish([list, item, button, editor])
        let listGroup = try XCTUnwrap(host.accessibilityElement(at: 0) as? UIAccessibilityElement)
        XCTAssertFalse(listGroup.isAccessibilityElement)
        XCTAssertEqual(listGroup.accessibilityContainerType, .semanticGroup)
        XCTAssertNil(listGroup.accessibilityLabel, "Structural groups do not repeat the authored label")
        let listElement = try XCTUnwrap(listGroup.accessibilityElement(at: 0) as? ExperienceSemanticAccessibilityElement)
        let itemGroup = try XCTUnwrap(listGroup.accessibilityElement(at: 1) as? UIAccessibilityElement)
        let itemElement = try XCTUnwrap(itemGroup.accessibilityElement(at: 0) as? ExperienceSemanticAccessibilityElement)
        let action = try XCTUnwrap(itemGroup.accessibilityElement(at: 1) as? ExperienceSemanticAccessibilityElement)
        XCTAssertEqual(itemGroup.accessibilityElementCount(), 3)
        XCTAssertTrue((itemGroup.accessibilityElement(at: 2) as? UITextField) === field)
        XCTAssertTrue(field.superview === host)
        XCTAssertEqual(action.accessibilityFrame, UIAccessibility.convertToScreenCoordinates(button.bounds, in: host))
        XCTAssertTrue(itemElement.accessibilityActivate())
        XCTAssertTrue(action.accessibilityActivate())
        XCTAssertEqual(actions, [2, 3])
        focused = action
        let reorderedEditor = node(4, 2, .textField, field.frame, order: 2)
        try publish([reorderedEditor, button, item, list])
        XCTAssertTrue(focused === action)
        XCTAssertTrue((host.accessibilityElement(at: 0) as? UIAccessibilityElement) === listGroup)
        XCTAssertTrue((itemGroup.accessibilityElement(at: 2) as? UIAccessibilityElement) === action)
        XCTAssertTrue((itemGroup.accessibilityElement(at: 1) as? UITextField) === field)
        host.isHidden = true
        XCTAssertFalse(action.accessibilityActivate())
        host.isHidden = false
        try publish([list, item, editor])
        XCTAssertTrue(focused === field, "Removing a focused action restores its surviving neighbor")
        XCTAssertFalse(action.accessibilityActivate())
        XCTAssertEqual(actions, [2, 3], "Focus restoration never activates a replacement")
        try publish([list])
        XCTAssertTrue((host.accessibilityElement(at: 0) as? UIAccessibilityElement) === listElement)
        XCTAssertEqual(listElement.accessibilityFrame, UIAccessibility.convertToScreenCoordinates(list.bounds, in: host))
        XCTAssertNil(listGroup.accessibilityElements)
        XCTAssertTrue(focused === listElement)
        container.clear()
        XCTAssertFalse(listElement.accessibilityActivate())
    }

    func testNestedVirtualContainersConvertFramesAndEnumerateRealEditors() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let host = UIView(frame: CGRect(x: 20, y: 30, width: 300, height: 500))
        controller.view.addSubview(host)
        let list = UIAccessibilityElement(accessibilityContainer: host)
        list.isAccessibilityElement = false
        list.accessibilityContainerType = .semanticGroup
        list.accessibilityFrameInContainerSpace = CGRect(x: 10, y: 15, width: 200, height: 300)
        let item = UIAccessibilityElement(accessibilityContainer: list)
        item.isAccessibilityElement = false
        item.accessibilityContainerType = .semanticGroup
        item.accessibilityFrameInContainerSpace = CGRect(x: 5, y: 7, width: 150, height: 60)
        let button = UIAccessibilityElement(accessibilityContainer: item)
        button.isAccessibilityElement = true
        button.accessibilityTraits = .button
        button.accessibilityFrameInContainerSpace = CGRect(x: 2, y: 3, width: 40, height: 20)
        let field = UITextField(frame: CGRect(x: 10, y: 90, width: 100, height: 30))
        host.addSubview(field)
        item.accessibilityElements = [button, field]
        list.accessibilityElements = [item]
        host.accessibilityElements = [list]
        XCTAssertEqual(button.accessibilityFrame,
            UIAccessibility.convertToScreenCoordinates(CGRect(x: 17, y: 25, width: 40, height: 20), in: host))
        XCTAssertEqual(item.accessibilityElementCount(), 2)
        XCTAssertTrue((item.accessibilityElement(at: 0) as? UIAccessibilityElement) === button)
        XCTAssertTrue((item.accessibilityElement(at: 1) as? UITextField) === field)
        XCTAssertTrue(field.superview === host)
        host.frame.origin.x += 25
        XCTAssertEqual(button.accessibilityFrame,
            UIAccessibility.convertToScreenCoordinates(CGRect(x: 17, y: 25, width: 40, height: 20), in: host))
    }
}
#endif
