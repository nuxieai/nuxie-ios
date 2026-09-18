#if canImport(UIKit) && NUXIE_HOSTED_INPUT_TESTS
import UIKit
import XCTest

/// Platform oracle for nesting virtual collection containers in UIKit.
@MainActor
final class UIKitAccessibilityContainerContractTests: XCTestCase {
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
