#if canImport(UIKit)
import UIKit
import XCTest
@testable import Nuxie
import NuxieRuntime

@MainActor
final class ExperienceSemanticAccessibilityContainerTests: XCTestCase {
    func testReadingOrderMixesNativeFieldOnceAndPreservesDrawnIdentity() throws {
        let view = UIView()
        let field = UITextField()
        view.addSubview(field)
        let container = ExperienceSemanticAccessibilityContainer(view: view)
        container.setActive(true)
        let nodes = [node(3, order: 2), node(2, order: 1, role: .textField), node(1, order: 0)]
        let capture = try capture(nodes)
        var requests = 0
        container.update(capture: capture, nativeControls: [2: field], project: projection) { _, _, _ in
            requests += 1
            return true
        }
        let items = try XCTUnwrap(view.accessibilityElements)
        XCTAssertEqual(items.count, 3)
        let first = try XCTUnwrap(items[0] as? ExperienceSemanticAccessibilityElement)
        XCTAssertTrue((items[1] as? UITextField) === field)
        XCTAssertEqual((items[2] as? UIAccessibilityElement)?.accessibilityLabel, "3")
        XCTAssertTrue(first.accessibilityActivate())
        container.update(capture: try self.capture(nodes), nativeControls: [2: field], project: projection) {
            _, _, _ in true
        }
        XCTAssertTrue((view.accessibilityElements?.first as? UIAccessibilityElement) === first)
        container.clear()
        XCTAssertEqual(view.accessibilityElements?.count, 0)
        XCTAssertFalse(first.accessibilityActivate())
        XCTAssertEqual(requests, 1)
    }

    func testHiddenSubtreeAndMissingNativeFieldDoNotBecomeVirtualChildren() throws {
        let view = UIView()
        let container = ExperienceSemanticAccessibilityContainer(view: view)
        container.setActive(true)
        let nodes = [node(3, parent: 1), node(2, role: .textField),
            node(1, flags: NuxieNativeSemanticNode.hidden), node(4)]
        container.update(capture: try capture(nodes), nativeControls: [:], project: projection) { _, _, _ in true }
        XCTAssertEqual(view.accessibilityElements?.count, 1)
        XCTAssertEqual((view.accessibilityElements?.first as? UIAccessibilityElement)?.accessibilityLabel, "4")
    }

    func testFocusWaitsForPresentationRestoresLogicalTargetAndDoesNotRepeat() throws {
        let view = UIView()
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        let nodes = [node(1), node(2, order: 1)]
        func publish() throws {
            container.update(capture: try capture(nodes), nativeControls: [:], project: projection) { _, _, _ in true }
        }
        try publish()
        XCTAssertTrue(moves.isEmpty)
        container.setActive(true)
        XCTAssertTrue(moves.isEmpty, "Activation alone has no presented target")
        try publish()
        XCTAssertEqual((moves.last as? UIAccessibilityElement)?.accessibilityLabel, "1")
        focused = view.accessibilityElements?[1] as AnyObject?
        try publish()
        XCTAssertEqual(moves.count, 1, "Stable frames preserve focus without announcements")
        container.setActive(false)
        XCTAssertEqual(view.accessibilityElements?.count, 0)
        try publish()
        XCTAssertEqual(moves.count, 1)
        container.setActive(true)
        try publish()
        XCTAssertEqual((moves.last as? UIAccessibilityElement)?.accessibilityLabel, "2")
        XCTAssertEqual(moves.count, 2)
        container.clear()
        container.setActive(true)
        try publish()
        XCTAssertEqual((moves.last as? UIAccessibilityElement)?.accessibilityLabel, "1", "Shutdown discards restoration")
    }

    func testRepeatedWithdrawalBeforePresentationPreservesOwnedRestoration() throws {
        let view = UIView()
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        func publish() throws {
            container.update(capture: try capture([node(1), node(2, order: 1)]),
                nativeControls: [:], project: projection) { _, _, _ in true }
        }
        container.setActive(true)
        try publish()
        focused = view.accessibilityElements?[1] as AnyObject?
        container.setActive(false)
        container.setActive(true)
        container.setActive(false)
        container.setActive(true)
        XCTAssertEqual(moves.count, 1)
        try publish()
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual((moves.last as? UIAccessibilityElement)?.accessibilityLabel, "2")
    }

    func testNativeFieldFocusAndRemovedTargetUseCurrentReadingOrder() throws {
        let view = UIView()
        let field = UITextField()
        view.addSubview(field)
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        func publish(_ nodes: [NuxieNativeSemanticNode]) throws {
            container.update(capture: try capture(nodes), nativeControls: [2: field], project: projection) { _, _, _ in true }
        }
        let nodes = [node(1), node(2, order: 1, role: .textField), node(3, order: 2)]
        container.setActive(true)
        try publish(nodes)
        focused = field
        container.setActive(false)
        container.setActive(true)
        try publish(nodes)
        XCTAssertTrue(moves.last === field)
        try publish([node(1), node(3, order: 2)])
        XCTAssertEqual((moves.last as? UIAccessibilityElement)?.accessibilityLabel, "3")
        XCTAssertEqual(moves.count, 3)
        try publish([node(1), node(3, order: 2)])
        XCTAssertEqual(moves.count, 3)
    }

    func testTemporaryWithdrawalDoesNotStealFocusFromNativeShell() throws {
        let view = UIView()
        let shellButton = UIButton()
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        func publish() throws {
            container.update(capture: try capture([node(1)]), nativeControls: [:], project: projection) { _, _, _ in true }
        }
        container.setActive(true)
        try publish()
        focused = shellButton
        container.setActive(false)
        container.setActive(true)
        try publish()
        XCTAssertEqual(moves.count, 1, "Temporary scene restoration must preserve shell focus")
        XCTAssertTrue(focused === shellButton)
    }

    func testFocusMovedWhileHiddenWinsUnlessNavigationRequestsHandoff() throws {
        let view = UIView()
        let shellButton = UIButton()
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        func publish() throws {
            container.update(capture: try capture([node(1)]), nativeControls: [:], project: projection) { _, _, _ in true }
        }
        container.setActive(true)
        try publish()
        container.setActive(false)
        focused = shellButton
        container.setActive(true)
        try publish()
        XCTAssertTrue(focused === shellButton)
        XCTAssertEqual(moves.count, 1)
        container.setActive(false)
        container.requestFocusOnNextPresentation()
        try publish()
        XCTAssertEqual(moves.count, 1, "An inactive destination cannot take focus")
        container.setActive(true)
        try publish()
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual((focused as? UIAccessibilityElement)?.accessibilityLabel, "1")
    }

    func testReplacingNativeEditorRestoresSameLogicalNode() throws {
        let view = UIView()
        let first = UITextField()
        let replacement = UITextField()
        view.addSubview(first)
        view.addSubview(replacement)
        var focused: AnyObject?
        var moves: [AnyObject] = []
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { moves.append($0); focused = $0 })
        func publish(_ field: UITextField) throws {
            container.update(capture: try capture([node(2, role: .textField)]), nativeControls: [2: field],
                project: projection) { _, _, _ in true }
        }
        container.setActive(true)
        try publish(first)
        XCTAssertTrue(focused === first)
        try publish(replacement)
        XCTAssertTrue(focused === replacement)
        XCTAssertEqual(moves.count, 2)
    }

    func testLatestLifecycleWriteOwnsFocusAcrossHideReactivateAndLateCompletion() {
        var lifecycle = ExperienceSemanticFocusLifecycle()
        let firstActivation = lifecycle.beginWrite()
        XCTAssertFalse(lifecycle.isReady)
        let hide = lifecycle.beginWrite(phase: .hidden)
        let secondActivation = lifecycle.beginWrite()
        XCTAssertFalse(lifecycle.completeWrite(firstActivation, succeeded: true))
        XCTAssertFalse(lifecycle.isReady, "Repeating active state cannot admit an older activation")
        XCTAssertFalse(lifecycle.completeWrite(hide, succeeded: true))
        XCTAssertTrue(lifecycle.completeWrite(secondActivation, succeeded: true))
        XCTAssertTrue(lifecycle.admitsHandoff(from: secondActivation))
        XCTAssertFalse(lifecycle.admitsHandoff(from: firstActivation))
        XCTAssertFalse(lifecycle.completeWrite(firstActivation, succeeded: false))
        XCTAssertTrue(lifecycle.isReady, "An obsolete failure cannot revoke the current focus lease")
        let failed = lifecycle.beginWrite()
        XCTAssertFalse(lifecycle.admitsHandoff(from: secondActivation))
        XCTAssertFalse(lifecycle.completeWrite(failed, succeeded: false))
        XCTAssertFalse(lifecycle.isReady)
        lifecycle = ExperienceSemanticFocusLifecycle()
        XCTAssertFalse(lifecycle.completeWrite(secondActivation, succeeded: true), "Teardown fences old acknowledgments")
    }

    func testActiveSettingsRefreshPreservesPresentedFocusButTransitionsWithdrawIt() throws {
        let view = UIView()
        var focused: AnyObject?
        var moves = 0
        let container = ExperienceSemanticAccessibilityContainer(view: view,
            focusedElement: { focused }, moveFocus: { focused = $0; moves += 1 })
        var lifecycle = ExperienceSemanticFocusLifecycle()
        func publish() throws {
            container.setActive(lifecycle.canExposeCurrentScene)
            container.update(capture: try capture([node(1)]), nativeControls: [:], project: projection) { _, _, _ in true }
        }
        let activation = lifecycle.beginWrite(phase: .active)
        try publish()
        XCTAssertNil(view.accessibilityElements)
        lifecycle.completeWrite(activation, succeeded: true)
        try publish()
        let original = try XCTUnwrap(view.accessibilityElements?.first as AnyObject?)
        let settings = lifecycle.beginWrite(phase: .active)
        XCTAssertFalse(lifecycle.isReady, "New handoffs still wait for the latest acknowledgment")
        try publish()
        XCTAssertTrue((view.accessibilityElements?.first as AnyObject?) === original)
        lifecycle.completeWrite(settings, succeeded: true)
        try publish()
        XCTAssertEqual(moves, 1)
        let exit = lifecycle.beginWrite(phase: .exiting)
        try publish()
        XCTAssertEqual(view.accessibilityElements?.count, 0)
        lifecycle.completeWrite(exit, succeeded: true)
        XCTAssertFalse(lifecycle.canExposeCurrentScene)
        let restore = lifecycle.beginWrite(phase: .active)
        try publish()
        XCTAssertEqual(view.accessibilityElements?.count, 0)
        lifecycle.completeWrite(restore, succeeded: true)
        try publish()
        XCTAssertEqual(moves, 2)
        let failedSettings = lifecycle.beginWrite(phase: .active)
        lifecycle.completeWrite(failedSettings, succeeded: false)
        try publish()
        XCTAssertEqual(view.accessibilityElements?.count, 0)
    }

    private func projection(_ node: NuxieNativeSemanticNode) -> ExperienceSemanticAccessibilityContainer.Projection? {
        .init(frame: node.bounds, traits: .button)
    }

    private func capture(_ nodes: [NuxieNativeSemanticNode]) throws -> NuxieNativeSemanticCapture {
        NuxieNativeSemanticCapture(id: UUID(), tree: try NuxieNativeSemanticTree(
            renderRevision: 1, treeVersion: 1, nodes: nodes), fieldsByTextRun: [:])
    }

    private func node(_ id: UInt32, parent: UInt32? = nil, order: UInt32 = 0,
        role: NuxieNativeSemanticRole = .button, flags: UInt32 = 0) -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(id: id, parentID: parent, siblingIndex: order, role: role.rawValue,
            stateFlags: flags, traitFlags: 0, headingLevel: 0, actions: 1,
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10), label: String(id), value: "", hint: "")
    }
}
#endif
