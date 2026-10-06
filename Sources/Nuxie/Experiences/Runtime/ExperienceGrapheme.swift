import Foundation

/// Unicode 16 extended grapheme boundaries, independent of the phone's Unicode version.
enum ExperienceGrapheme {
    private enum Kind: UInt32 {
        case other, cr, lf, control, extend, zwj, regionalIndicator, prepend, spacingMark
        case l, v, t, lv, lvt
        var isControl: Bool { self == .cr || self == .lf || self == .control }
    }
    private enum Indic: UInt32 { case none, consonant, linker, extend }
    private enum Emoji { case none, pictograph, joined }
    private struct Property {
        let kind: Kind
        let indic: Indic
        let pictographic: Bool
        init(_ scalar: UInt32) {
            var packed: UInt32 = 0
            if (0xac00...0xd7a3).contains(scalar) {
                packed = (scalar - 0xac00) % 28 == 0 ? 12 : 13
            } else if !(0x20...0x7e).contains(scalar) {
                let ranges = ExperienceGraphemeData.ranges
                var low = 0
                var high = ranges.count / 3
                while low < high {
                    let middle = (low + high) / 2
                    let offset = middle * 3
                    if scalar < ranges[offset] { high = middle }
                    else if scalar > ranges[offset + 1] { low = middle + 1 }
                    else { packed = ranges[offset + 2]; break }
                }
            }
            kind = Kind(rawValue: packed & 15)!
            indic = Indic(rawValue: (packed >> 4) & 3)!
            pictographic = packed & 64 != 0
        }
    }

    private struct Context {
        var previous: Kind = .other
        var regionalCount = 0
        var emoji: Emoji = .none
        var indicConsonant = false
        var indicLinker = false

        func breaks(before next: Property) -> Bool {
            let current = next.kind
            if previous == .cr && current == .lf { return false } // GB3
            if previous.isControl || current.isControl { return true } // GB4, GB5
            if previous == .l && (current == .l || current == .v || current == .lv || current == .lvt) { return false } // GB6
            if (previous == .lv || previous == .v) && (current == .v || current == .t) { return false } // GB7
            if (previous == .lvt || previous == .t) && current == .t { return false } // GB8
            if current == .extend || current == .zwj || current == .spacingMark { return false } // GB9, GB9a
            if previous == .prepend { return false } // GB9b
            if indicLinker && next.indic == .consonant { return false } // GB9c
            if emoji == .joined && next.pictographic { return false } // GB11
            if previous == .regionalIndicator && current == .regionalIndicator && regionalCount % 2 == 1 {
                return false // GB12, GB13
            }
            return true
        }

        mutating func append(_ next: Property) {
            if next.kind == .regionalIndicator { regionalCount += 1 } else { regionalCount = 0 }
            if next.pictographic { emoji = .pictograph }
            else if next.kind == .extend && emoji == .pictograph { }
            else if next.kind == .zwj && emoji == .pictograph { emoji = .joined }
            else { emoji = .none }
            switch next.indic {
            case .consonant: indicConsonant = true; indicLinker = false
            case .linker: indicLinker = indicConsonant
            case .extend: break
            case .none: indicConsonant = false; indicLinker = false
            }
            previous = next.kind
        }
    }

    static func forEachCluster(in text: String, _ consume: (Range<String.Index>, Int) -> Void) {
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var context = Context()
        var byteCount = 0
        for index in scalars.indices {
            let scalar = scalars[index].value
            let property = Property(scalar)
            if index != start && context.breaks(before: property) {
                consume(start..<index, byteCount)
                start = index
                byteCount = 0
                context = Context()
            }
            context.append(property)
            byteCount += scalar <= 0x7f ? 1 : scalar <= 0x7ff ? 2 : scalar <= 0xffff ? 3 : 4
        }
        if start != scalars.endIndex { consume(start..<scalars.endIndex, byteCount) }
    }
}
