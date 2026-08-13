import Foundation

struct ExperienceScreenTransitionSpec: Equatable {
    enum Kind: Equatable, CaseIterable {
        case none
        case push
        case modal
        case fade
        case custom(transitionId: String)

        static let allCases: [Kind] = [.none, .push, .modal, .fade]

        var rawValue: String {
            switch self {
            case .none: "none"
            case .push: "push"
            case .modal: "modal"
            case .fade: "fade"
            case .custom: "custom"
            }
        }
    }

    let kind: Kind

    var isAnimated: Bool {
        switch kind {
        case .none:
            return false
        case .push, .modal, .fade, .custom:
            return true
        }
    }

    func effectiveKind(reduceMotion: Bool) -> Kind {
        kind
    }

    func shouldAnimate(reduceMotion: Bool) -> Bool {
        isAnimated && !reduceMotion
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

        self.init(kind: ExperienceScreenTransitionSpec.kind(from: record))
    }

    private static func transitionRecord(from raw: Any?) -> [String: Any]? {
        if let anyCodable = raw as? AnyCodable {
            return transitionRecord(from: anyCodable.value)
        }
        return raw as? [String: Any]
    }

    private static func kind(from record: [String: Any]) -> Kind {
        guard let raw = record["type"] as? String else { return .none }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            return .none
        case "push":
            return .push
        case "modal":
            return .modal
        case "fade":
            return .fade
        case "custom":
            guard
                let rawTransitionId = record["transitionId"] as? String,
                !rawTransitionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .none
            }
            return .custom(transitionId: rawTransitionId)
        default:
            // Unknown kinds fall back to an instant transition.
            return .none
        }
    }

}
