import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Shared destination policy for native links and journey open-link steps.
enum ExperienceLinkRouting {
    static func destination(urlString: String, target: String?, parser: (String) -> URL? = parse) -> (url: URL, inApp: Bool)? {
        guard urlString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = parser(urlString), let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else { return nil }
        let web = scheme == "http" || scheme == "https"
        if web && (url.host?.isEmpty != false) { return nil }
        let target = target?.lowercased() ?? "_self"
        return (url, web && ["", "_self", "_parent", "_top", "in_app"].contains(target))
    }

    @MainActor
    @discardableResult
    static func open(urlString: String, target: String?, parser: (String) -> URL? = parse,
                     inApp: @MainActor (URL) async -> Bool, external: @MainActor (URL) async -> Bool) async -> Bool {
        guard let route = destination(urlString: urlString, target: target, parser: parser) else { return false }
        return await (route.inApp ? inApp(route.url) : external(route.url))
    }
    static func parse(_ value: String) -> URL? {
        if #available(iOS 17, macOS 14, *) {
            return URL(string: value, encodingInvalidCharacters: true)
        }
        return parseLegacy(value)
    }

    /// RFC 3986 escaping and IDNA host conversion for Foundation before iOS 17.
    static func parseLegacy(_ value: String) -> URL? {
        var value = value
        if let authority = value.range(of: "://") {
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
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: escaped)
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
