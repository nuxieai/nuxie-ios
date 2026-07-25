import XCTest
@testable import Nuxie

final class JourneyHandoffContractTests: XCTestCase {
    func testDecodesOpaqueHandoffMarker() throws {
        let data = Data(
            """
            {
              "type": "handoff",
              "nodeId": "handoff-node",
              "edgeId": "edge-1",
              "direction": "device_to_server",
              "toRegionId": "server-region",
              "toNodeId": "email-node"
            }
            """.utf8
        )

        guard case .handoff(let handoff) = try JSONDecoder().decode(JourneyAction.self, from: data) else {
            return XCTFail("Expected handoff action")
        }
        XCTAssertEqual(handoff.edgeId, "edge-1")
        XCTAssertEqual(handoff.direction, "device_to_server")
        XCTAssertEqual(handoff.toRegionId, "server-region")
        XCTAssertEqual(handoff.toNodeId, "email-node")
    }

    func testTransferredStatusIsTerminal() {
        XCTAssertFalse(JourneyStatus.transferred.isActive)
        XCTAssertTrue(JourneyStatus.transferred.isTerminal)
        XCTAssertFalse(JourneyStatus.transferred.isLive)
    }
}
