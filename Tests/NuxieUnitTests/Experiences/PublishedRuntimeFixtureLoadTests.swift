#if canImport(UIKit)
@testable import Nuxie
import UIKit
import XCTest

@MainActor
final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    func testFlowRuntimeFixtureHandlersDeclareTheirEvents() throws {
        let fixturesRoot = try Self.fixturesRootURL()
        let fixtureFiles = try XCTUnwrap(
            FileManager.default.enumerator(
                at: fixturesRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )

        for case let fixtureURL as URL in fixtureFiles
        where fixtureURL.lastPathComponent.hasPrefix("flow-description")
            && fixtureURL.pathExtension == "json" {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
                    as? [String: Any],
                fixtureURL.path
            )
            let events = object["events"] as? [String: [[String: Any]]] ?? [:]
            let handlers = object["handlers"] as? [String: [[String: Any]]] ?? [:]

            for (host, hostedHandlers) in handlers {
                let declarations = Set(
                    (events[host] ?? []).compactMap { $0["eventName"] as? String }
                )
                for handler in hostedHandlers {
                    let eventName = try XCTUnwrap(
                        handler["eventName"] as? String,
                        "\(fixtureURL.path): handler on \(host) is missing eventName"
                    )
                    XCTAssertTrue(
                        declarations.contains(eventName),
                        "\(fixtureURL.path): \(host) handler event \(eventName) is undeclared"
                    )
                }
            }
        }
    }

    func testPublishedRuntimeFixturesMountThroughFixtureHost() throws {
        for fixtureName in ["published-font", "text-input-motion"] {
            try XCTContext.runActivity(named: fixtureName) { _ in
                let root = try Self.fixtureURL(named: fixtureName)
                let cacheRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nuxie-published-runtime-fixture-tests", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let viewController = try FlowRuntimeFixtureHost.makeViewController(
                    fixtureBaseURL: root,
                    cacheRootURL: cacheRoot
                )
                viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
                viewController.loadViewIfNeeded()

                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline,
                      Self.findSubview(identifier: "nuxie-flow-surface", in: viewController.view) == nil {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }

                XCTAssertNotNil(
                    Self.findSubview(identifier: "nuxie-flow-surface", in: viewController.view),
                    "Expected \(fixtureName) to mount through FlowRuntimeFixtureHost"
                )
            }
        }
    }

    private static func fixturesRootURL() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("FlowRuntimeHostApp", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func fixtureURL(named fixtureName: String) throws -> URL {
        try fixturesRootURL()
            .appendingPathComponent(fixtureName, isDirectory: true)
    }

    private static func findSubview(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = findSubview(identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}
#endif
