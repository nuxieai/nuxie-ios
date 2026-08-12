import Foundation
import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

final class NuxPackageLifecycleManifestTests: XCTestCase {
    func testDecodesScreenExitAndChoreographedTransition() throws {
        let data = try manifestData { root in
            var screens = try XCTUnwrap(root["screens"] as? [[String: Any]])
            screens[0]["exit"] = [
                "completeEventName": "checkout.exit.complete",
                "durationMs": 300,
            ]
            root["screens"] = screens
            root["transitions"] = [[
                "id": "checkout-to-success",
                "kind": "choreographed",
                "sourceScreenId": "checkout",
                "destinationScreenId": "success",
                "durationMs": 450,
                "incomingOnTop": true,
                "source": ["completeEventName": "checkout.transition.complete"],
                "destination": ["completeEventName": "success.transition.complete"],
                "reverse": [
                    "durationMs": 250,
                    "incomingOnTop": false,
                    "source": ["completeEventName": "success.reverse.complete"],
                    "destination": ["completeEventName": "checkout.reverse.complete"],
                ],
            ]]
        }

        let manifest = try JSONDecoder().decode(NuxPackageManifestV1.self, from: data)

        XCTAssertEqual(
            manifest.screens.first?.exit,
            NuxPackageScreenExit(completeEventName: "checkout.exit.complete", durationMs: 300)
        )
        XCTAssertEqual(manifest.transitions?.first?.id, "checkout-to-success")
        XCTAssertEqual(manifest.transitions?.first?.kind, .choreographed)
        XCTAssertEqual(manifest.transitions?.first?.sourceScreenId, "checkout")
        XCTAssertEqual(manifest.transitions?.first?.destinationScreenId, "success")
        XCTAssertEqual(manifest.transitions?.first?.reverse?.durationMs, 250)
        XCTAssertEqual(
            manifest.transitions?.first?.reverse?.destination.completeEventName,
            "checkout.reverse.complete"
        )
    }

    func testDecodesManifestWithoutLifecycleMetadata() throws {
        let data = try manifestData()

        let manifest = try JSONDecoder().decode(NuxPackageManifestV1.self, from: data)

        XCTAssertNil(manifest.transitions)
        XCTAssertTrue(manifest.screens.allSatisfy { $0.exit == nil })
    }

    func testRejectsMalformedLifecycleMetadata() throws {
        let malformedExit = try manifestData { root in
            var screens = try XCTUnwrap(root["screens"] as? [[String: Any]])
            screens[0]["exit"] = [
                "completeEventName": "checkout.exit.complete",
                "durationMs": "slow",
            ]
            root["screens"] = screens
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(NuxPackageManifestV1.self, from: malformedExit)
        )

        let malformedTransition = try manifestData { root in
            root["transitions"] = [[
                "id": "checkout-to-success",
                "kind": "fade",
                "sourceScreenId": "checkout",
                "destinationScreenId": "success",
                "durationMs": 450,
                "incomingOnTop": true,
                "source": ["completeEventName": "checkout.transition.complete"],
                "destination": ["completeEventName": "success.transition.complete"],
            ]]
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(NuxPackageManifestV1.self, from: malformedTransition)
        )

        let unknownNestedField = try manifestData { root in
            var screens = try XCTUnwrap(root["screens"] as? [[String: Any]])
            screens[0]["exit"] = [
                "completeEventName": "checkout.exit.complete",
                "durationMs": 300,
                "unexpected": true,
            ]
            root["screens"] = screens
        }
        let unknownRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unknownNestedField) as? [String: Any]
        )
        XCTAssertThrowsError(try NuxManifestUnknownFieldValidator.validate(unknownRoot))

        let negativeDuration = NuxPackageManifestV1.test(
            entryScreenId: "checkout",
            screens: [
                NuxPackageScreen(
                    screenId: "checkout",
                    artboardId: "checkout-artboard",
                    artboardName: "Checkout",
                    width: 390,
                    height: 844,
                    exit: NuxPackageScreenExit(
                        completeEventName: "checkout.exit.complete",
                        durationMs: -1
                    )
                ),
            ]
        )
        XCTAssertThrowsError(try NuxPackageSwiftVerifier.validateManifest(negativeDuration))
    }

    private func manifestData(
        mutate: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> Data {
        let manifest = NuxPackageManifestV1.test(
            entryScreenId: "checkout",
            screens: [
                NuxPackageScreen(
                    screenId: "checkout",
                    artboardId: "checkout-artboard",
                    artboardName: "Checkout",
                    width: 390,
                    height: 844,
                    exit: nil
                ),
                NuxPackageScreen(
                    screenId: "success",
                    artboardId: "success-artboard",
                    artboardName: "Success",
                    width: 390,
                    height: 844,
                    exit: nil
                ),
            ]
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any]
        )
        try mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
