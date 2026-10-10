import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared destination policy for native links and journey open-link steps.
enum ExperienceLinkRouting {
    enum State { case settled, closed, background }

    static func route(urlString: String, target: String?, state: State, parser: (String) -> URL? = parse) -> (url: URL, destination: String)? {
        guard state != .background, let link = destination(urlString: urlString, target: target, parser: parser) else { return nil }
        return (link.url, state == .settled && link.inApp ? "in_app" : "external")
    }

    static func destination(urlString: String, target: String?, parser: (String) -> URL? = parse) -> (url: URL, inApp: Bool)? {
        guard urlString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = parser(urlString), let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else { return nil }
        let web = scheme == "http" || scheme == "https"
        if web && (url.host?.isEmpty != false) { return nil }
        let target = target?.lowercased() ?? "_self"
        return (url, web && ["", "_self", "_parent", "_top", "in_app"].contains(target))
    }

    static func parse(_ value: String) -> URL? {
        if #available(iOS 17, macOS 14, *) {
            return URL(string: value, encodingInvalidCharacters: true)
        }
        return parseLegacy(value)
    }

    /// RFC 3986 escaping and IDNA host conversion for Foundation before iOS 17.
    static func parseLegacy(_ value: String, parser: (String) -> URL? = { URL(string: $0) }) -> URL? {
        var value = value
        if let colon = value.firstIndex(of: ":"),
           let authority = value.range(of: "://"), authority.lowerBound == colon {
            let end = value[authority.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
            let raw = String(value[authority.upperBound..<end])
            let userEnd = raw.lastIndex(of: "@").map { raw.index(after: $0) } ?? raw.startIndex
            let hostEnd = raw[userEnd...].firstIndex(of: ":") ?? raw.endIndex
            let host = String(raw[userEnd..<hostEnd])
            if host.unicodeScalars.contains(where: { !$0.isASCII }) {
                let labels = host.precomposedStringWithCanonicalMapping.lowercased().split(separator: ".", omittingEmptySubsequences: false)
                let encoded = labels.map { label -> String in
                    label.unicodeScalars.allSatisfy(\.isASCII) ? String(label) : "xn--" + punycode(String(label))
                }.joined(separator: ".")
                value.replaceSubrange(authority.upperBound..<end,
                    with: String(raw[..<userEnd]) + encoded + String(raw[hostEnd...]))
            }
        }
        let scalars = Array(value.unicodeScalars)
        let authority = value.range(of: "://").flatMap { range -> Range<String.Index>? in
            guard value.firstIndex(of: ":") == range.lowerBound else { return nil }
            let end = value[range.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? value.endIndex
            let start = value[range.upperBound..<end].lastIndex(of: "@").map { value.index(after: $0) } ?? range.upperBound
            let hostEnd: String.Index
            if value[start..<end].first == "[", let bracket = value[start..<end].firstIndex(of: "]") { hostEnd = value.index(after: bracket) }
            else { hostEnd = value[start..<end].firstIndex(of: ":") ?? end }
            return start..<hostEnd
        }
        let hostOffsets = authority.map { value.unicodeScalars.distance(from: value.startIndex, to: $0.lowerBound)..<value.unicodeScalars.distance(from: value.startIndex, to: $0.upperBound) }
        var normalized = "", fragmentSeen = false
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        for (index, scalar) in scalars.enumerated() {
            if scalar == "%", !(index + 2 < scalars.count && hex.contains(scalars[index + 1]) && hex.contains(scalars[index + 2])) {
                normalized += "%25"
            } else if (scalar == "[" || scalar == "]") && !(hostOffsets?.contains(index) ?? false) {
                normalized += scalar == "[" ? "%5B" : "%5D"
            } else if scalar == "#" {
                normalized += fragmentSeen ? "%23" : "#"
                fragmentSeen = true
            } else { normalized.unicodeScalars.append(scalar) }
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard let escaped = normalized.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return parser(escaped)
    }

    private static func punycode(_ label: String) -> String {
        let points = label.unicodeScalars.map { Int($0.value) }
        var output = String(label.unicodeScalars.filter(\.isASCII))
        let basic = output.utf8.count
        var handled = basic, n = 128, delta = 0, bias = 72
        if basic > 0 { output += "-" }
        func digit(_ value: Int) -> Character {
            Character(UnicodeScalar(value < 26 ? value + 97 : value - 26 + 48)!)
        }
        while handled < points.count {
            let next = points.filter { $0 >= n }.min()!
            delta += (next - n) * (handled + 1)
            n = next
            for point in points {
                if point < n { delta += 1 }
                if point == n {
                    var q = delta, k = 36
                    while true {
                        let threshold = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                        if q < threshold { break }
                        output.append(digit(threshold + (q - threshold) % (36 - threshold)))
                        q = (q - threshold) / (36 - threshold)
                        k += 36
                    }
                    output.append(digit(q))
                    var adapted = handled == basic ? delta / 700 : delta / 2
                    adapted += adapted / (handled + 1)
                    var shift = 0
                    while adapted > 455 { adapted /= 35; shift += 36 }
                    bias = shift + 36 * adapted / (adapted + 38)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    @MainActor
    static func openExternal(_ value: String) async -> Bool {
        guard let route = destination(urlString: value, target: "external") else { return false }
        #if canImport(UIKit)
        return await UIApplication.shared.open(route.url, options: [:])
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(route.url)
        #else
        return false
        #endif
    }
}
