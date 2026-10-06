#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceHardwareKeyTests: XCTestCase {
    func testHardwareTableMatchesSharedOracle() throws {
        struct Vector: Decodable {
            struct Key: Decodable {
                let iosHid: Int
                let rive: UInt16
            }
            let keys: [Key]
            let modifiers: [String: UInt8]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/input/hardware-keys.json")
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
        XCTAssertEqual(vector.keys.count, 119)
        for key in vector.keys { XCTAssertEqual(ExperienceHardwareKey.code(hid: key.iosHid), key.rive) }
        #if os(iOS)
        let modifiers: [(UIKeyModifierFlags, String)] = [(.shift, "shift"), (.control, "control"), (.alternate, "alt"), (.command, "meta")]
        for (flags, name) in modifiers {
            XCTAssertEqual(ExperienceHardwareKey.modifiers(flags), vector.modifiers[name])
        }
        XCTAssertEqual(ExperienceHardwareKey.modifiers([.shift, .control, .alternate, .command]), 15)
        XCTAssertEqual(ExperienceHardwareKey.modifiers([.alphaShift, .numericPad]), 0)
        #endif
        XCTAssertNil(ExperienceHardwareKey.code(hid: 0))
        XCTAssertNil(ExperienceHardwareKey.code(hid: 65_535))
        XCTAssertEqual(ExperienceHardwareKey.input(hid: 43, modifiers: 0, pressed: true, repeated: false), .next)
        XCTAssertEqual(ExperienceHardwareKey.input(hid: 43, modifiers: 1, pressed: true, repeated: false), .previous)
        XCTAssertNil(ExperienceHardwareKey.input(hid: 43, modifiers: 0, pressed: false, repeated: false))
        XCTAssertEqual(ExperienceHardwareKey.input(hid: 225, modifiers: 1, pressed: true, repeated: false),
            .key(code: 340, modifiers: 1, pressed: true, repeated: false))
        XCTAssertEqual(ExperienceHardwareKey.input(hid: 4, modifiers: 9, pressed: true, repeated: true),
            .key(code: 65, modifiers: 9, pressed: true, repeated: true))
    }
}
#endif
