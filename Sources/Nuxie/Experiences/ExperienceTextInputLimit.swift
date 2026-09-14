/// Unicode 16 extended graphemes (UAX #29 rev. 45), shared with Android.
enum ExperienceTextInputLimit {
    static func fits(_ text: String, maximum: Int?) -> Bool {
        apply(text, maximum: maximum).utf8.count == text.utf8.count
    }

    static func apply(_ text: String, maximum: Int?) -> String {
        guard let maximum else { return text }
        precondition(maximum >= 0)
        let scalars = text.unicodeScalars
        var clusters = 0
        var previous = Kind.other
        var regionalCount = 0
        var emojiPrefix = false
        var emojiBeforeZwj = false
        var indicConsonant = false
        var indicLinker = false
        for index in scalars.indices {
            let properties = UnicodeGraphemeProperties.get(Int(scalars[index].value))
            let kind = Kind(rawValue: properties & 15) ?? .other
            let indic = properties & 48
            let pictographic = properties & 64 != 0
            let boundary: Bool
            if index == scalars.startIndex { boundary = true } // GB1
            else if previous == .cr && kind == .lf { boundary = false } // GB3
            else if previous.isControl || kind.isControl { boundary = true } // GB4/5
            else if previous == .l && [.l, .v, .lv, .lvt].contains(kind) { boundary = false } // GB6
            else if [.lv, .v].contains(previous) && [.v, .t].contains(kind) { boundary = false } // GB7
            else if [.lvt, .t].contains(previous) && kind == .t { boundary = false } // GB8
            else if [.extend, .zwj, .spacingMark].contains(kind) { boundary = false } // GB9/9a
            else if previous == .prepend { boundary = false } // GB9b
            else if indic == 16 && indicConsonant && indicLinker { boundary = false } // GB9c
            else if pictographic && previous == .zwj && emojiBeforeZwj { boundary = false } // GB11
            else if previous == .regional && kind == .regional && regionalCount % 2 == 1 { boundary = false } // GB12/13
            else { boundary = true } // GB999
            if boundary {
                if clusters == maximum { return String(scalars[..<index]) }
                clusters += 1
            }
            emojiBeforeZwj = kind == .zwj && emojiPrefix
            emojiPrefix = pictographic || (kind == .extend && emojiPrefix)
            switch indic {
            case 16: indicConsonant = true; indicLinker = false
            case 48: if indicConsonant { indicLinker = true }
            case 32: break
            default: indicConsonant = false; indicLinker = false
            }
            regionalCount = kind == .regional ? regionalCount + 1 : 0
            previous = kind
        }
        return text
    }

    private enum Kind: Int {
        case other = 0, control, cr, lf, extend, zwj, regional, prepend, spacingMark, l, v, t, lv, lvt
        var isControl: Bool { self == .control || self == .cr || self == .lf }
    }
}
