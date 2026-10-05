import Foundation

/// Shared destination policy for native links and journey open-link steps.
enum ExperienceLinkRouting {
    static func destination(urlString: String, target: String?) -> (url: URL, inApp: Bool)? {
        guard urlString.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else { return nil }
        let web = scheme == "http" || scheme == "https"
        if web && (url.host?.isEmpty != false) { return nil }
        let target = target?.lowercased() ?? "_self"
        return (url, web && ["", "_self", "_parent", "_top", "in_app"].contains(target))
    }

    @MainActor
    @discardableResult
    static func open(urlString: String, target: String?,
                     inApp: @MainActor (URL) async -> Bool, external: @MainActor (URL) async -> Bool) async -> Bool {
        guard let route = destination(urlString: urlString, target: target) else { return false }
        return await (route.inApp ? inApp(route.url) : external(route.url))
    }
}
