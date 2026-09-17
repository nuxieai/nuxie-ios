#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
import XCTest
@testable import Nuxie

@MainActor
final class ExperienceVideoCaptionOverlayTests: XCTestCase {
    func testIndependentCaptionsPreserveAccessibilityIdentityAndClearEndedCues() throws {
        let overlay = ExperienceVideoCaptionOverlay()
        overlay.update([
            .init(componentID: 7, language: "en", text: "Welcome"),
            .init(componentID: 9, language: "fr", text: "Bonjour"),
        ])
        let english = try XCTUnwrap(overlay.arrangedSubviews.first as? UILabel)
        let french = try XCTUnwrap(overlay.arrangedSubviews.last as? UILabel)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertFalse(overlay.isAccessibilityElement)
        XCTAssertTrue(english.isAccessibilityElement)
        XCTAssertTrue(english.accessibilityTraits.contains(.staticText))
        XCTAssertTrue(english.adjustsFontForContentSizeCategory)
        XCTAssertEqual(english.accessibilityLabel, "Welcome")
        XCTAssertEqual(english.accessibilityLanguage, "en")
        XCTAssertEqual(french.accessibilityLabel, "Bonjour")
        XCTAssertEqual(french.accessibilityLanguage, "fr")

        overlay.update([
            .init(componentID: 9, language: "fr", text: "Au revoir"),
            .init(componentID: 7, language: "", text: "Next"),
        ])
        XCTAssertTrue(overlay.arrangedSubviews.first === french)
        XCTAssertTrue(overlay.arrangedSubviews.last === english)
        XCTAssertEqual(french.text, "Au revoir")
        XCTAssertEqual(english.text, "Next")
        XCTAssertNil(english.accessibilityLanguage)
        overlay.update([.init(componentID: 7, language: "en", text: "")])
        XCTAssertTrue(overlay.arrangedSubviews.isEmpty)
        XCTAssertNil(english.superview)
        XCTAssertNil(french.superview)
    }
}
#endif
