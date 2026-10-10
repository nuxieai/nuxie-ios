#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import NuxieRuntime
#if os(iOS)
import UIKit
#endif

/// USB HID usages from UIKeyboardHIDUsage, mapped to Rive's GLFW codes.
enum ExperienceHardwareKey {
    static func code(hid: Int) -> UInt16? {
        if (4...29).contains(hid) { return UInt16(hid + 61) }
        if (30...38).contains(hid) { return UInt16(hid + 19) }
        if (58...69).contains(hid) { return UInt16(hid + 232) }
        if (104...115).contains(hid) { return UInt16(hid + 198) }
        if (89...97).contains(hid) { return UInt16(hid + 232) }
        return special[hid]
    }

    static func input(hid: Int, modifiers: UInt8, pressed: Bool, repeated: Bool) -> NuxieNativeFocusInput? {
        guard let code = code(hid: hid) else { return nil }
        if code == 258 {
            guard pressed else { return nil }
            return modifiers & 1 == 0 ? .next : .previous
        }
        return .key(code: code, modifiers: modifiers, pressed: pressed, repeated: repeated)
    }

    #if os(iOS)
    static func modifiers(_ flags: UIKeyModifierFlags) -> UInt8 {
        var value: UInt8 = 0
        if flags.contains(.shift) { value |= 1 }
        if flags.contains(.control) { value |= 2 }
        if flags.contains(.alternate) { value |= 4 }
        if flags.contains(.command) { value |= 8 }
        return value
    }
    #endif

    private static let special: [Int: UInt16] = [
        39: 48, 40: 257, 41: 256, 42: 259, 43: 258, 44: 32,
        45: 45, 46: 61, 47: 91, 48: 93, 49: 92, 50: 92, 51: 59,
        52: 39, 53: 96, 54: 44, 55: 46, 56: 47, 57: 280,
        70: 283, 71: 281, 72: 284, 73: 260, 74: 268, 75: 266,
        76: 261, 77: 269, 78: 267, 79: 262, 80: 263, 81: 264,
        82: 265, 83: 282, 84: 331, 85: 332, 86: 333, 87: 334,
        88: 335, 98: 320, 99: 330, 100: 161, 101: 348, 103: 336,
        224: 341, 225: 340, 226: 342, 227: 343,
        228: 345, 229: 344, 230: 346, 231: 347,
    ]
}
#endif
