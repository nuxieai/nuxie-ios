import CoreGraphics
import Foundation
import XCTest
@testable import Nuxie
#if canImport(UIKit)
import UIKit
#endif

final class ExperienceLayoutFixtureTests: XCTestCase {
    func testSharedLayoutVectors() throws {
        struct Fixture: Decodable {
            struct Vector: Decodable {
                let name: String
                let view, origin, pixelPoint, runtimePoint, semanticRect, viewRect: [Double]
                let scale: Double
            }
            let cases: [Vector]
        }
        let fixture: Fixture = try readFixture("runtime-layout-transform")
        for v in fixture.cases {
            let transform = try XCTUnwrap(ExperienceLayoutTransform(
                artboardBounds: CGRect(x: v.origin[0], y: v.origin[1], width: v.view[0], height: v.view[1]),
                viewportBounds: CGRect(x: 0, y: 0, width: v.view[0], height: v.view[1])))
            let point = transform.artboardPoint(fromViewport: CGPoint(x: v.pixelPoint[0] / v.scale, y: v.pixelPoint[1] / v.scale))
            XCTAssertEqual(point, CGPoint(x: v.runtimePoint[0], y: v.runtimePoint[1]), v.name)
            let rect = transform.viewportRect(fromArtboard: CGRect(x: v.semanticRect[0], y: v.semanticRect[1], width: v.semanticRect[2], height: v.semanticRect[3]))
            XCTAssertEqual(rect, CGRect(x: v.viewRect[0], y: v.viewRect[1], width: v.viewRect[2], height: v.viewRect[3]), v.name)
        }
    }

    #if canImport(UIKit)
    @MainActor
    func testSharedSafeAreaVectorsPublishTheViewInsets() throws {
        struct Fixture: Decodable {
            struct Vector: Decodable {
                let name: String
                let view, pixelInsets, expected: [Double]
                let scale: Double
            }
            let cases: [Vector]
        }
        let fixture: Fixture = try readFixture("runtime-safe-area")
        for v in fixture.cases {
            let view = InsetsView(frame: CGRect(x: 0, y: 0, width: v.view[0], height: v.view[1]))
            view.insets = UIEdgeInsets(top: v.pixelInsets[0] / v.scale, left: v.pixelInsets[2] / v.scale, bottom: v.pixelInsets[1] / v.scale, right: v.pixelInsets[3] / v.scale)
            let actual = experienceSafeAreaInsets(for: view)
            XCTAssertEqual([actual.top, actual.bottom, actual.left, actual.right], v.expected, v.name)
        }
    }
    #endif

    private func readFixture<T: Decodable>(_ name: String) throws -> T {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/\(name).json")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

#if canImport(UIKit)
@MainActor
private final class InsetsView: UIView {
    var insets: UIEdgeInsets = .zero
    override var safeAreaInsets: UIEdgeInsets { insets }
}
#endif
