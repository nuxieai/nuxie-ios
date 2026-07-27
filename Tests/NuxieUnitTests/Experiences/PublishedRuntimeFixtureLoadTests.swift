#if canImport(UIKit)
@testable import Nuxie
import UIKit
import XCTest

@MainActor
final class PublishedRuntimeFixtureLoadTests: XCTestCase {
    func testFixtureBuildIdentityIncludesDetachedManifestSignature() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nuxie-fixture-signature-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let rivData = Data("fixture-riv".utf8)
        try rivData.write(to: root.appendingPathComponent("flow.riv"))
        let manifestData = Data(
            """
            {
              "version": 1,
              "flowId": "signed-fixture",
              "buildId": "signed-fixture-build",
              "renderer": "rive",
              "riv": {
                "path": "flow.riv",
                "sha256": "\(ExperienceArtifactStore.sha256Hex(rivData))",
                "sizeBytes": \(rivData.count)
              },
              "entry": {
                "screenId": "screen",
                "artboardId": "screen",
                "artboardName": "Screen",
                "width": 160,
                "height": 100
              },
              "screens": [{
                "screenId": "screen",
                "artboardId": "screen",
                "artboardName": "Screen",
                "width": 160,
                "height": 100
              }],
              "assets": { "images": [], "fonts": [] },
              "textInputs": []
            }
            """.utf8
        )
        let manifest = try JSONDecoder().decode(
            FlowArtifactManifest.self,
            from: manifestData
        )
        let signatureURL = root.appendingPathComponent(
            ExperienceManifestSignature.artifactPath
        )
        try Data("first-signature".utf8).write(to: signatureURL)

        let files = try FlowRuntimeFixtureHost.buildFiles(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: root
        )
        XCTAssertEqual(
            files.map(\.path),
            [
                ExperienceArtifactStore.manifestPath,
                "flow.riv",
                ExperienceManifestSignature.artifactPath,
            ]
        )

        let firstHash = FlowRuntimeFixtureHost.contentHash(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: root
        )
        try Data("second-signature".utf8).write(to: signatureURL)
        let secondHash = FlowRuntimeFixtureHost.contentHash(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: root
        )
        XCTAssertNotEqual(
            firstHash,
            secondHash,
            "A signature-only change must invalidate the prepared fixture cache"
        )
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

    private static func fixtureURL(named fixtureName: String) throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
            .appendingPathComponent("FlowRuntimeHostApp", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
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
