import CoreGraphics
import Foundation
import XCTest
@testable import Nuxie
#if canImport(UIKit)
import UIKit
#endif
#if canImport(RiveRuntime)
import RiveRuntime
#endif

final class FlowSafeAreaInsetMapperTests: XCTestCase {
    private let accuracy = 1e-9

    private func map(
        _ deviceInsets: FlowSafeAreaInsets,
        view: CGSize,
        artboard: CGSize
    ) -> FlowSafeAreaInsets {
        FlowSafeAreaInsetMapper.artboardInsets(
            deviceInsets: deviceInsets,
            viewSize: view,
            artboardSize: artboard
        )
    }

    private func assertInsets(
        _ actual: FlowSafeAreaInsets,
        top: Double,
        bottom: Double,
        left: Double,
        right: Double,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.top, top, accuracy: accuracy, "top", line: line)
        XCTAssertEqual(actual.bottom, bottom, accuracy: accuracy, "bottom", line: line)
        XCTAssertEqual(actual.left, left, accuracy: accuracy, "left", line: line)
        XCTAssertEqual(actual.right, right, accuracy: accuracy, "right", line: line)
    }

    func testIdentityWhenArtboardMatchesViewExactly() {
        // iPhone-island portrait: scale 1, no letterbox, insets pass through.
        let result = map(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0),
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 390, height: 844)
        )
        assertInsets(result, top: 59, bottom: 34, left: 0, right: 0)
    }

    func testScaledDownArtboardGrowsInsetsByInverseScale() {
        // Artboard authored at 2x the view: scale 0.5, no letterbox, so a
        // 59pt device inset covers 118 artboard units.
        let result = map(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0),
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 780, height: 1688)
        )
        assertInsets(result, top: 118, bottom: 68, left: 0, right: 0)
    }

    func testUpscaledArtboardShrinksInsetsByInverseScale() {
        // Artboard authored at half the view: scale 2, no letterbox.
        let result = map(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0),
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 195, height: 422)
        )
        assertInsets(result, top: 29.5, bottom: 17, left: 0, right: 0)
    }

    func testLetterboxFullyEatsVerticalInsets() {
        // Square artboard centered in a tall view: letterboxY = 227pt, far
        // larger than either vertical inset, so both clamp to zero.
        let result = map(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0),
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 390, height: 390)
        )
        assertInsets(result, top: 0, bottom: 0, left: 0, right: 0)
    }

    func testLetterboxPartiallyEatsVerticalInsets() {
        // Artboard 390x800 in a 390x844 view: scale 1, letterboxY = 22pt.
        let result = map(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0),
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 390, height: 800)
        )
        assertInsets(result, top: 37, bottom: 12, left: 0, right: 0)
    }

    func testPillarboxEatsHorizontalInsetsOnly() {
        // Narrow artboard centered in a wide view: letterboxX = 250pt eats
        // the 47pt side insets; the vertical axis has no letterbox so the
        // bottom inset passes through untouched.
        let result = map(
            FlowSafeAreaInsets(top: 0, bottom: 21, left: 47, right: 47),
            view: CGSize(width: 800, height: 400),
            artboard: CGSize(width: 300, height: 400)
        )
        assertInsets(result, top: 0, bottom: 21, left: 0, right: 0)
    }

    func testRotationSwapWithScaledPillarbox() {
        // Portrait-authored artboard (390x780) rendered in a landscape view
        // (780x390): scale = 0.5, scaled artboard = 195x390, letterboxX =
        // 292.5 (eats the 47pt notch side insets), letterboxY = 0 (bottom
        // 21pt home-indicator inset maps to 42 artboard units).
        let result = map(
            FlowSafeAreaInsets(top: 0, bottom: 21, left: 47, right: 47),
            view: CGSize(width: 780, height: 390),
            artboard: CGSize(width: 390, height: 780)
        )
        assertInsets(result, top: 0, bottom: 42, left: 0, right: 0)
    }

    func testLandscapeIdentityPassesSideInsetsThrough() {
        // Landscape-authored artboard matching the landscape view exactly.
        let result = map(
            FlowSafeAreaInsets(top: 0, bottom: 21, left: 59, right: 59),
            view: CGSize(width: 844, height: 390),
            artboard: CGSize(width: 844, height: 390)
        )
        assertInsets(result, top: 0, bottom: 21, left: 59, right: 59)
    }

    func testScaledLetterboxCombinesScaleAndOffset() {
        // Artboard 200x400 in a 100x300 view: scale = 0.5, scaled artboard =
        // 100x200, letterboxY = 50. A 60pt top inset overlaps the artboard by
        // 10pt of view space = 20 artboard units.
        let result = map(
            FlowSafeAreaInsets(top: 60, bottom: 40, left: 8, right: 0),
            view: CGSize(width: 100, height: 300),
            artboard: CGSize(width: 200, height: 400)
        )
        assertInsets(result, top: 20, bottom: 0, left: 16, right: 0)
    }

    func testZeroInsetsStayZero() {
        let result = map(
            .zero,
            view: CGSize(width: 390, height: 844),
            artboard: CGSize(width: 780, height: 1688)
        )
        assertInsets(result, top: 0, bottom: 0, left: 0, right: 0)
    }

    func testDegenerateViewSizeReturnsZero() {
        let insets = FlowSafeAreaInsets(top: 59, bottom: 34, left: 10, right: 10)
        assertInsets(
            map(insets, view: .zero, artboard: CGSize(width: 390, height: 844)),
            top: 0, bottom: 0, left: 0, right: 0
        )
        assertInsets(
            map(insets, view: CGSize(width: 390, height: 0), artboard: CGSize(width: 390, height: 844)),
            top: 0, bottom: 0, left: 0, right: 0
        )
    }

    func testDegenerateArtboardSizeReturnsZero() {
        let insets = FlowSafeAreaInsets(top: 59, bottom: 34, left: 10, right: 10)
        assertInsets(
            map(insets, view: CGSize(width: 390, height: 844), artboard: .zero),
            top: 0, bottom: 0, left: 0, right: 0
        )
        assertInsets(
            map(insets, view: CGSize(width: 390, height: 844), artboard: CGSize(width: 0, height: 844)),
            top: 0, bottom: 0, left: 0, right: 0
        )
    }

    func testNeverReturnsNegativeInsets() {
        // Insets smaller than the letterbox band clamp to zero instead of
        // going negative; the non-letterboxed axis passes through at scale 1.
        let result = map(
            FlowSafeAreaInsets(top: 1, bottom: 2, left: 3, right: 4),
            view: CGSize(width: 400, height: 800),
            artboard: CGSize(width: 400, height: 400)
        )
        assertInsets(result, top: 0, bottom: 0, left: 3, right: 4)
    }

    #if canImport(UIKit)
    func testInitFromUIEdgeInsets() {
        let insets = FlowSafeAreaInsets(UIEdgeInsets(top: 59, left: 1, bottom: 34, right: 2))
        assertInsets(insets, top: 59, bottom: 34, left: 1, right: 2)
    }
    #endif
}

#if canImport(RiveRuntime) && canImport(UIKit)
@MainActor
final class FlowViewModelBridgeSafeAreaTests: XCTestCase {
    func testPushBeforeBindReportsNotBound() throws {
        let bridge = try makeBridge()

        let outcome = bridge.pushSafeAreaInsets(
            FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0)
        )

        XCTAssertEqual(outcome, .notBound)
    }

    func testPushWithoutSafeAreaViewModelReportsUnsupportedWithoutThrowing() throws {
        // The fixture's "Test" view model predates the safe-area env system
        // and has no safeArea object; pushes must degrade quietly (the caller
        // logs once per screen) rather than crash or throw.
        let bridge = try makeBridge()
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        let insets = FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0)
        XCTAssertEqual(bridge.pushSafeAreaInsets(insets), .unsupported)
        // Repeat pushes stay tolerant.
        XCTAssertEqual(bridge.pushSafeAreaInsets(insets), .unsupported)
        XCTAssertEqual(bridge.pushSafeAreaInsets(.zero), .unsupported)
    }

    func testPushDoesNotDisturbOtherBoundProperties() throws {
        let bridge = try makeBridge()
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())
        try bridge.setNumber(44, path: "Number")

        _ = bridge.pushSafeAreaInsets(FlowSafeAreaInsets(top: 59, bottom: 34, left: 0, right: 0))

        XCTAssertEqual(try bridge.numberValue(path: "Number"), 44)
    }

    private func makeBridge() throws -> FlowViewModelBridge {
        let bundle = Bundle(for: FlowViewModelBridgeSafeAreaTests.self)
        let url = bundle.url(forResource: "data_binding_test", withExtension: "riv", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "data_binding_test", withExtension: "riv")
        let fixtureURL = try XCTUnwrap(url)
        let data = try Data(contentsOf: fixtureURL)
        let file = try RiveFile(data: data, loadCdn: false)
        let model = RiveModel(riveFile: file)
        try model.setArtboard()
        try model.setStateMachine("State Machine 1")
        return FlowViewModelBridge(model: model)
    }
}
#endif
