#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime

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
