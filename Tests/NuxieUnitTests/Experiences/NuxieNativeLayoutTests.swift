#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@testable import Nuxie

final class NuxieNativeLayoutTests: XCTestCase {
    func testFixedLayoutSizeRoundTripsAfterZeroStep() async throws {
        let runtime = try await openRuntime()
        do {
            for width in [Float(300), 500] {
                try await runtime.setLayoutSize(width: width, height: 600)
                _ = try await runtime.step(elapsedSeconds: 0)
                let size = try await runtime.layoutSize()
                XCTAssertEqual(size, CGSize(width: CGFloat(width), height: 600))
            }
            for width in [Float.zero, -1, .nan, .infinity] {
                do {
                    try await runtime.setLayoutSize(width: width, height: 600)
                    XCTFail("Invalid width must be refused")
                } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
                    XCTAssertEqual(diagnostic.status, .invalidArgument)
                }
                let size = try await runtime.layoutSize()
                XCTAssertEqual(size, CGSize(width: 500, height: 600))
            }
            try await runtime.close()
        } catch {
            try? await runtime.close()
            throw error
        }
    }

    func testLayoutRenderRejectsInvalidScaleAndConsumesCompletion() async throws {
        let runtime = try await openRuntime()
        do {
            for scale in [Float.zero, -1, .nan, .infinity] {
                let completed = expectation(description: "invalid layout scale completion")
                do {
                    _ = try await runtime.render(layoutScaleFactor: scale, drawable: .timeout,
                        completion: { completed.fulfill() })
                    XCTFail("Invalid layout scale must be refused")
                } catch NuxieNativeRuntimeError.callFailed(let diagnostic) {
                    XCTAssertEqual(diagnostic.status, .invalidArgument)
                }
                await fulfillment(of: [completed], timeout: 2)
            }
            try await runtime.close()
        } catch {
            try? await runtime.close()
            throw error
        }
    }

    func testBoundRootHeightUsesUpstreamLayoutAndRestoresFixed() async throws {
        for control in [false, true] {
            let runtime = try await openHeightRuntime(control: control)
            let height = ExperiencePresentationHeight()
            do {
                for (width, available, hug, expected) in [
                    (Float(300), Float(600), false, Float(600)),
                    (300, 600, true, control ? 600 : 152),
                    (300, 700, false, 700),
                    (500, 600, true, control ? 600 : 152),
                ] {
                    _ = try await height.apply(to: runtime, fitContent: hug, width: width, height: available)
                    _ = try await runtime.step(elapsedSeconds: 0)
                    let size = try await runtime.layoutSize()
                    XCTAssertEqual(size.width, CGFloat(width))
                    XCTAssertEqual(size.height, CGFloat(expected))
                }
                try await runtime.close()
            } catch { try? await runtime.close(); throw error }
        }
    }

    func testHeightInstancesAreIndependentBetweenPlayers() async throws {
        let prepared = try await prepareHeightFile(control: false)
        let group = try await prepared.makeSessionGroup()
        let artboards = try await prepared.artboards()
        let name = try XCTUnwrap(artboards.first).name
        let first = try await group.openSession(artboardName: name, player: .defaultScene,
            pixelWidth: 300, pixelHeight: 600, bindDefaultViewModel: true)
        let second = try await group.openSession(artboardName: name, player: .defaultScene,
            pixelWidth: 500, pixelHeight: 700, bindDefaultViewModel: true)
        do {
            _ = try await ExperiencePresentationHeight().apply(to: first, fitContent: true, width: 300, height: 600)
            _ = try await ExperiencePresentationHeight().apply(to: second, fitContent: false, width: 500, height: 700)
            _ = try await first.step(elapsedSeconds: 0)
            _ = try await second.step(elapsedSeconds: 0)
            let a = try await first.layoutSize(), b = try await second.layoutSize()
            XCTAssertEqual(a, CGSize(width: 300, height: 152))
            XCTAssertEqual(b, CGSize(width: 500, height: 700))
            try await first.close(); try await second.close()
        } catch { try? await first.close(); try? await second.close(); throw error }
    }

    func testMissingHeightGlobalLeavesFixedSizeAvailable() async throws {
        let runtime = try await openRuntime()
        do {
            let available = try await ExperiencePresentationHeight().apply(to: runtime,
                fitContent: true, width: 300, height: 600)
            XCTAssertFalse(available)
            _ = try await runtime.step(elapsedSeconds: 0)
            let size = try await runtime.layoutSize()
            XCTAssertEqual(size, CGSize(width: 300, height: 600))
            try await runtime.close()
        } catch { try? await runtime.close(); throw error }
    }

    func testFillAndOversizedChildrenKeepUpstreamHeightSemantics() async throws {
        for (name, expected) in [("fill-child", CGFloat(32)), ("tall-child", CGFloat(1232))] {
            let prepared = try await prepareHeightFile(name: name)
            let runtime = try await prepared.openSession(artboardName: "Sheet", player: .defaultScene,
                pixelWidth: 300, pixelHeight: 600)
            do {
                _ = try await ExperiencePresentationHeight().apply(to: runtime,
                    fitContent: true, width: 300, height: 600)
                _ = try await runtime.step(elapsedSeconds: 0)
                let size = try await runtime.layoutSize()
                XCTAssertEqual(size.height, expected)
                try await runtime.close()
            } catch { try? await runtime.close(); throw error }
        }
    }

    private func prepareHeightFile(control: Bool) async throws -> NuxieNativePreparedFile {
        try await prepareHeightFile(name: control ? "root-height-no-binding" : "root-height-binding")
    }

    private func prepareHeightFile(name: String) async throws -> NuxieNativePreparedFile {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/runtime/fit-content/\(name).riv"))
        return try await NuxieNativePreparedFile.prepare(bytes: bytes, importMode: .portable)
    }

    private func openHeightRuntime(control: Bool) async throws -> NuxieNativeRuntime {
        let prepared = try await prepareHeightFile(control: control)
        let artboards = try await prepared.artboards()
        return try await prepared.openSession(artboardName: XCTUnwrap(artboards.first).name,
            player: .defaultScene, pixelWidth: 300, pixelHeight: 600)
    }

    private func openRuntime() async throws -> NuxieNativeRuntime {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "semantic_text", withExtension: "riv"))
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: Data(contentsOf: url), importMode: .portable)
        let artboards = try await prepared.artboards()
        let name = try XCTUnwrap(artboards.first).name
        return try await prepared.openSession(artboardName: name, player: .staticArtboard,
            pixelWidth: 900, pixelHeight: 1800)
    }
}
#endif
