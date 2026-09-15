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
        let nodes = [node(3, parent: 1), node(2, role: .textField),
            node(1, flags: NuxieNativeSemanticNode.hidden), node(4)]
        container.update(capture: try capture(nodes), nativeControls: [:], project: projection) { _, _, _ in true }
        XCTAssertEqual(view.accessibilityElements?.count, 1)
        XCTAssertEqual((view.accessibilityElements?.first as? UIAccessibilityElement)?.accessibilityLabel, "4")
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
