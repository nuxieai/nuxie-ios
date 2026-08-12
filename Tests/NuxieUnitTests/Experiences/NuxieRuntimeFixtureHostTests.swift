#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
@_spi(Testing) @testable import Nuxie

/// Guards repeat presentation through the same Swift-owned runtime path used
/// by the product fixture host.
@MainActor
final class NuxieRuntimeFixtureHostTests: XCTestCase {
    func testSignedPackageMountsAfterPriorHostIsReleased() throws {
        var firstHost: UIViewController? = try makeHost(cacheLabel: "first")
        firstHost?.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        firstHost?.loadViewIfNeeded()
        XCTAssertNotNil(try waitForSurface(in: XCTUnwrap(firstHost)))
        firstHost = nil

        let secondHost = try makeHost(cacheLabel: "second")
        secondHost.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        secondHost.loadViewIfNeeded()
        XCTAssertNotNil(try waitForSurface(in: secondHost))
    }

    private func makeHost(cacheLabel: String) throws -> UIViewController {
        let fixtureRoot = try fixturesRootURL()
            .appendingPathComponent("animation-event", isDirectory: true)
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nux-runtime-host-tests", isDirectory: true)
            .appendingPathComponent("\(cacheLabel)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        return try ExperienceRuntimeFixtureHost.makeViewController(
            fixtureBaseURL: fixtureRoot,
            cacheRootURL: cacheRoot
        )
    }

    private func waitForSurface(in viewController: UIViewController) throws -> UIView? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let surface = findSubview(
                identifier: "nuxie-experience-surface",
                in: viewController.view
            ) {
                return surface
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func fixturesRootURL() throws -> URL {
        let candidates = [
            Bundle(for: Self.self).resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("ExperienceRuntimeHostApp/Fixtures", isDirectory: true),
        ].compactMap { $0 }
        guard let root = candidates.first(where: {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("fixture-index.json").path
            )
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private func findSubview(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.findSubview(identifier: identifier, in: $0)
        }.first
    }
}
#endif
