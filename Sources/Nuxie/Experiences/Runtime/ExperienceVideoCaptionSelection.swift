#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import MediaAccessibility

enum ExperienceVideoCaptionSelection {
    // ISO 639-2 bibliographic aliases used in MP4 language metadata.
    // https://www.loc.gov/standards/iso639-2/php/code_list.php
    private static let bibliographicLanguages = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh",
        "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
        "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms",
        "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    static var preferredLanguages: [String] {
        let selected = MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []
        return selected + Locale.preferredLanguages
    }

    static func index(languages: [String?], preferred: [String]) -> Int? {
        guard !languages.isEmpty else { return nil }
        func normalized(_ value: String) -> String {
            var values = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-").lowercased().components(separatedBy: "-")
            values[0] = bibliographicLanguages[values[0]] ?? values[0]
            return Locale.canonicalLanguageIdentifier(from: values.joined(separator: "-")).lowercased()
        }
        func parts(_ tag: String) -> (String, String?) {
            let values = tag.split(separator: "-").map(String.init)
            return (values.first ?? "", values.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) })
        }
        let available = languages.map { normalized($0 ?? "") }
        for preference in preferred {
            let desired = normalized(preference)
            let (language, script) = parts(desired)
            guard !language.isEmpty && language != "und" else { continue }
            if let exact = available.firstIndex(of: desired) { return exact }
            let compatible = available.indices.filter {
                let (candidateLanguage, candidateScript) = parts(available[$0])
                return candidateLanguage == language && (script == nil || candidateScript == nil || script == candidateScript)
            }
            if let script, let match = compatible.first(where: { parts(available[$0]).1 == script }) { return match }
            if let base = compatible.first(where: { available[$0] == language }) { return base }
            if let first = compatible.first { return first }
        }
        // Retain the authored manifest order when none of the preferred languages exists.
        return 0
    }
}
#endif
