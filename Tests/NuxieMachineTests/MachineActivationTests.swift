#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
import NuxieMachine
import NuxieRuntime

/// Which of a machine Screen's elements a screen reader can activate, from
/// hand-built nodes shown the way the Screen shows every node of a frame.
/// A button the engine offers a tap for activates, and the activation is
/// sent to the Screen. A button the engine offers no action for (actions 0,
/// as for a node a scroll clips wholly away) is still read, as a button with
/// its words, and activating it sends nothing: the Screen's activation is a
/// tap at the element's point, which would press whatever is drawn there.
final class MachineActivationTests: XCTestCase {
    private static let surface = CGRect(x: 0, y: 0, width: 390, height: 844)

    @MainActor
    func testAButtonTheEngineOffersNoActionForIsReadButNotActivated() throws {
        let tap: UInt32 = 1 << NuxieNativeSemanticAction.tap.rawValue
        for (actions, activates) in [(tap, true), (UInt32(0), false)] {
            let node = NuxieNativeSemanticNode(
                id: 7, parentID: nil, siblingIndex: 0, role: NuxieNativeSemanticRole.button.rawValue,
                stateFlags: 0, traitFlags: 0, headingLevel: 0, actions: actions,
                bounds: CGRect(x: 24, y: 700, width: 342, height: 44),
                label: "Restore purchases", value: "", hint: "")
            let projection = try XCTUnwrap(NuxieMachineScreenViewController.projection(for: node, on: Self.surface),
                                           "a button with actions \(actions) is no element")
            let element = ExperienceSemanticAccessibilityElement(accessibilityContainer: UIView())
            var sent: [UInt32] = []
            element.update(captureID: UUID(), node: node, projection: projection) { _, id, _ in
                sent.append(id)
                return true
            }
            XCTAssertTrue(element.isAccessibilityElement, "actions \(actions): the button is not read")
            XCTAssertEqual(element.accessibilityLabel, "Restore purchases")
            XCTAssertTrue(element.accessibilityTraits.contains(.button), "actions \(actions): not read as a button")
            XCTAssertEqual(element.accessibilityActivate(), activates, "actions \(actions)")
            XCTAssertEqual(sent, activates ? [7] : [],
                           activates ? "the offered tap was not sent" : "a tap was sent for a node with no action")
        }
    }
}
#endif
