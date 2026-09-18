import Foundation
import XCTest
@testable import NuxieRuntime

final class NuxieNativeSemanticTreeTests: XCTestCase {
    func testCaptureWithdrawsEditorsOutsideActiveModalAndRestoresAfterDismissal() throws {
        let background = node(id: 1, role: 6)
        let modal = node(id: 2, flags: NuxieNativeSemanticNode.modal, role: 14)
        let field = node(id: 3, parent: 2, role: 6)
        let hidden = node(id: 4, parent: 2, flags: NuxieNativeSemanticNode.hidden, role: 6)
        let fields = ["background": background, "dialog": field, "hidden": hidden]
        for (scope, expected) in [(NuxieNativeSemanticModalScope.active(2), Set(["dialog"])),
                                  (.unresolved, Set<String>()), (.none, Set(["background", "dialog"]))] {
            let tree = try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
                nodes: [field, background, hidden, modal], modalScope: scope)
            let capture = NuxieNativeSemanticCapture(id: UUID(), tree: tree, fieldsByTextRun: fields)
            XCTAssertEqual(Set(capture.fieldsByTextRun.keys), expected)
        }
    }

    func testDisabledAncestorProjectsToChildBeforeParentAndReenablesFromFreshCapture() throws {
        let child = node(id: UInt32.max, parent: 1)
        let parent = node(id: 1, flags: 64)
        let disabled = try tree([child, parent])
        XCTAssertEqual(disabled.nodes.map(\.id), [UInt32.max, 1])
        XCTAssertTrue(disabled.nodes.allSatisfy { $0.stateFlags & 64 != 0 })
        XCTAssertEqual(child.stateFlags, 0)
        let enabled = try tree([child, node(id: 1)])
        XCTAssertTrue(enabled.nodes.allSatisfy { $0.stateFlags & 64 == 0 })
        XCTAssertEqual(enabled.renderRevision, 7)
        XCTAssertEqual(enabled.treeVersion, 9)
    }

    func testDisabledSiblingDoesNotDisableOtherBranches() throws {
        let result = try tree([node(id: 1), node(id: 2, parent: 1, flags: 64), node(id: 3, parent: 1)])
        XCTAssertEqual(result.nodes.map(\.stateFlags), [0, 64, 0])
    }

    func testHiddenAncestorHidesDescendantsWithoutHidingSiblingsAndFreshCaptureRestoresThem() throws {
        let hidden = NuxieNativeSemanticNode.hidden
        let child = node(id: 3, parent: 2)
        let root = node(id: 1)
        let sibling = node(id: 4, parent: 1)
        let result = try tree([child, node(id: 2, parent: 1, flags: hidden), root, sibling])
        XCTAssertEqual(result.nodes.map(\.stateFlags), [hidden, hidden, 0, 0])
        XCTAssertEqual(child.stateFlags, 0)
        let restored = try tree([child, node(id: 2, parent: 1), root, sibling])
        XCTAssertTrue(restored.nodes.allSatisfy { $0.stateFlags & hidden == 0 })
    }

    func testReadingOrderKeepsNestedGroupsTogetherAndUsesStableTies() throws {
        let result = try tree([
            node(id: 5, parent: 1, order: 2),
            node(id: 3, parent: 2, order: 1),
            node(id: 2, parent: 1, order: 0),
            node(id: 4, parent: 2, order: 0),
            node(id: 6, parent: 1, order: 2),
            node(id: 7, order: 1),
            node(id: 1, order: 0),
        ])
        XCTAssertEqual(result.visibleReadingOrder.map(\.id), [1, 2, 4, 3, 5, 6, 7])
    }

    func testInvalidHierarchyRejectsTheCompleteCapture() {
        XCTAssertThrowsError(try tree([node(id: 1), node(id: 1)])) {
            XCTAssertEqual($0 as? NuxieNativeSemanticTreeError, .duplicateIdentity(1))
        }
        XCTAssertThrowsError(try tree([node(id: 1, parent: 2)])) {
            XCTAssertEqual($0 as? NuxieNativeSemanticTreeError, .missingAncestor(2))
        }
        XCTAssertThrowsError(try tree([node(id: 1, parent: 2), node(id: 2, parent: 1)])) {
            XCTAssertEqual($0 as? NuxieNativeSemanticTreeError, .cyclicHierarchy)
        }
    }

    func testMaximumDepthUsesIterativeInheritanceAndRejectsLargerCaptures() throws {
        var nodes: [NuxieNativeSemanticNode] = []
        for id: UInt32 in 1...16_384 {
            let parent: UInt32? = id == 1 ? nil : id - 1
            let flags: UInt32 = id == 1 ? 64 : 0
            nodes.append(node(id: id, parent: parent, flags: flags))
        }
        let result = try tree(Array(nodes.reversed()))
        XCTAssertEqual(result.nodes.count, 16_384)
        XCTAssertEqual(result.visibleReadingOrder.map(\.id), Array(UInt32(1)...UInt32(16_384)))
        XCTAssertTrue(result.nodes.allSatisfy { $0.stateFlags & 64 != 0 })
        XCTAssertThrowsError(try tree(nodes + [node(id: 16_385)])) {
            XCTAssertEqual($0 as? NuxieNativeSemanticTreeError, .tooManyNodes)
        }
    }

    func testUnicodeLabelsSurviveButObscuredValuesAreNeverCopied() throws {
        let result = try tree([node(id: 1, flags: 4096)])
        XCTAssertEqual(result.nodes[0].label, "Prénom 👋")
        XCTAssertEqual(result.nodes[0].value, "")
        XCTAssertEqual(result.nodes[0].hint, "Votre nom")
    }

    func testModalScopeRequiresAVisibleModalAndPreservesFullIdentity() throws {
        let id = UInt32.max
        let modal = node(id: id, flags: NuxieNativeSemanticNode.modal, role: 14)
        let result = try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
            nodes: [modal], modalScope: .active(id))
        XCTAssertEqual(result.modalScope, .active(id))
        for nodes in [[], [node(id: id)],
            [node(id: id, flags: NuxieNativeSemanticNode.modal | NuxieNativeSemanticNode.hidden, role: 14)],
            [node(id: 1, flags: NuxieNativeSemanticNode.hidden),
             node(id: id, parent: 1, flags: NuxieNativeSemanticNode.modal, role: 14)]] {
            XCTAssertThrowsError(try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
                nodes: nodes, modalScope: .active(id))) {
                XCTAssertEqual($0 as? NuxieNativeSemanticTreeError, .invalidModalIdentity(id))
            }
        }
        let unresolved = try NuxieNativeSemanticTree(renderRevision: 1, treeVersion: 1,
            nodes: [modal], modalScope: .unresolved)
        XCTAssertEqual(unresolved.modalScope, .unresolved)
    }

    func testSharedCollectionCaptureContract() throws {
        struct Node: Decodable {
            let id: UInt32
            let parentId: UInt32?
            let role: UInt32
            let collectionId: UInt32?
            let itemCount: UInt32?
            let itemPosition: UInt32?
        }
        struct Scenario: Decodable { let id: String; let nodes: [Node]; let valid: Bool }
        struct Suite: Decodable { let schemaVersion: Int; let cases: [Scenario] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let suite = try JSONDecoder().decode(Suite.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/accessibility/collections.json")))
        XCTAssertEqual(suite.schemaVersion, 1)
        for scenario in suite.cases {
            let nodes = scenario.nodes.map { item in
                NuxieNativeSemanticNode(id: item.id, parentID: item.parentId, siblingIndex: 0,
                    role: item.role, stateFlags: 0, traitFlags: 0, headingLevel: 0, actions: 0,
                    bounds: .zero, label: "Item", value: "", hint: "",
                    collectionID: item.collectionId, itemCount: item.itemCount, itemPosition: item.itemPosition)
            }
            if scenario.valid {
                let result = try tree(nodes)
                XCTAssertEqual(result.nodes, nodes, scenario.id)
            } else {
                XCTAssertThrowsError(try tree(nodes), scenario.id) { error in
                    guard case NuxieNativeSemanticTreeError.invalidCollectionMetadata = error else {
                        return XCTFail("Unexpected error: \(error)", file: #filePath, line: #line)
                    }
                }
            }
        }
    }

    private func tree(_ nodes: [NuxieNativeSemanticNode]) throws -> NuxieNativeSemanticTree {
        try NuxieNativeSemanticTree(renderRevision: 7, treeVersion: 9, nodes: nodes)
    }

    private func node(id: UInt32, parent: UInt32? = nil, flags: UInt32 = 0, order: UInt32 = 0, role: UInt32 = 6) -> NuxieNativeSemanticNode {
        NuxieNativeSemanticNode(id: id, parentID: parent, siblingIndex: order, role: role,
            stateFlags: flags, traitFlags: 0, headingLevel: 0, actions: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 30),
            label: "Prénom 👋", value: "private fixture value", hint: "Votre nom")
    }
}
