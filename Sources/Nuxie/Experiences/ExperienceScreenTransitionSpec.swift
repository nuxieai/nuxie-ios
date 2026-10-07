import Foundation

struct ExperienceScreenTransitionSpec: Equatable, Sendable {
    enum Kind: Equatable, CaseIterable, Sendable {
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
    let presentation: ExperienceLayerPresentation
    private let presentationIsSupported: Bool
    var isAvailable: Bool { presentationIsSupported }

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

    init(kind: Kind, presentation: ExperienceLayerPresentation = .modalDefault, presentationIsSupported: Bool = true) {
        self.kind = kind
        self.presentation = presentation
        self.presentationIsSupported = presentationIsSupported
    }

    init(raw: Any?) {
        guard let record = ExperienceScreenTransitionSpec.transitionRecord(from: raw) else {
            self = .none
            return
        }

        let kind = ExperienceScreenTransitionSpec.kind(from: record)
        self.init(kind: kind, presentation: kind == .modal ? ExperienceLayerPresentation(
            kind: (record["present"] as? String).flatMap(ExperienceLayerPresentation.Kind.init(rawValue:)) ?? .sheet,
            height: (record["height"] as? String).flatMap(ExperienceLayerPresentation.Height.init(rawValue:)) ?? .large,
            closedBy: (record["closedby"] as? String).flatMap(ExperienceLayerPresentation.ClosedBy.init(rawValue:)) ?? .any
        ) : .modalDefault, presentationIsSupported: kind != .modal || record["present"] == nil
            || (record["present"] as? String).flatMap(ExperienceLayerPresentation.Kind.init(rawValue:)) != nil)
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
