import Foundation

struct ExperienceScreenTransitionSpec: Equatable {
    enum Kind: String {
        case none
        case push
        case modal
        case fade
    }

    let kind: Kind

    var isAnimated: Bool {
        kind == .push || kind == .modal || kind == .fade
    }

    static let none = ExperienceScreenTransitionSpec(kind: .none)

    init(kind: Kind) {
        self.kind = kind
    }

    init(raw: Any?) {
        guard let record = ExperienceScreenTransitionSpec.transitionRecord(from: raw) else {
            self = .none
            return
        }

        self.init(kind: ExperienceScreenTransitionSpec.kind(from: record["type"]))
    }

    private static func transitionRecord(from raw: Any?) -> [String: Any]? {
        if let anyCodable = raw as? AnyCodable {
            return transitionRecord(from: anyCodable.value)
        }
        return raw as? [String: Any]
    }

    private static func kind(from raw: Any?) -> Kind {
        guard let raw = raw as? String else { return .none }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            return .none
        case "push":
            return .push
        case "modal":
            return .modal
        case "fade":
            return .fade
        default:
            // Unknown kinds (including the never-implemented "custom") fall
            // back to an instant transition.
            return .none
        }
    }

}
