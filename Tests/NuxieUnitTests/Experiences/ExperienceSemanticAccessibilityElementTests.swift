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
        element.update(captureID: first, node: node(actions: 1), frameInContainer: .zero,
            traits: .button) { requests.append(($0, $1, $2)); return true }
        XCTAssertTrue(element.accessibilityActivate())
        element.accessibilityIncrement()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, first)
        XCTAssertEqual(requests.first?.1, UInt32.max)
        let second = UUID()
        element.update(captureID: second, node: node(actions: 6), frameInContainer: .zero,
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
        element.update(captureID: UUID(), node: node(actions: 7, flags: NuxieNativeSemanticNode.disabled),
            frameInContainer: CGRect(x: 2, y: 3, width: 4, height: 5), traits: .button, submit: submit)
        XCTAssertTrue(element.accessibilityTraits.contains(.notEnabled))
        XCTAssertEqual(element.accessibilityLabel, "Prénom 👋")
        XCTAssertEqual(element.accessibilityFrameInContainerSpace, CGRect(x: 2, y: 3, width: 4, height: 5))
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        element.accessibilityDecrement()
        XCTAssertEqual(calls, 0)
        element.update(captureID: UUID(), node: node(actions: 1), frameInContainer: .zero,
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
        element.update(captureID: UUID(), node: node(actions: 1), frameInContainer: .zero,
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
        element.update(captureID: UUID(), node: node(actions: 7, flags: NuxieNativeSemanticNode.hidden),
            frameInContainer: .zero, traits: .button) { _, _, _ in
                XCTFail("Hidden controls cannot submit actions")
                return true
            }
        XCTAssertFalse(element.isAccessibilityElement)
        XCTAssertFalse(element.accessibilityActivate())
        element.accessibilityIncrement()
        element.accessibilityDecrement()
    }

    private func node(actions: UInt32, flags: UInt32 = 0) -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(id: .max, parentID: nil, siblingIndex: 0, role: 1,
            stateFlags: flags, traitFlags: 0, headingLevel: 0, actions: actions,
            bounds: .zero, label: "Prénom 👋", value: "", hint: "Activate")
    }
}
#endif
