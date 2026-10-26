import Foundation

struct ExperienceScreenTransitionSpec: Equatable, Sendable {
    enum Kind: Equatable, CaseIterable, Sendable {
        case none
        case push
        case modal
        case fade
        case magicMove
        case custom(transitionId: String)

        static let allCases: [Kind] = [.none, .push, .modal, .fade, .magicMove]

        var rawValue: String {
            switch self {
            case .none: "none"
            case .push: "push"
            case .modal: "modal"
            case .fade: "fade"
            case .magicMove: "magic-move"
            case .custom: "custom"
            }
        }
    }

    let kind: Kind
    let transitionId: String?
    let presentation: ExperienceLayerPresentation
    private let presentationIsSupported: Bool
    var isAvailable: Bool { presentationIsSupported }

    var isAnimated: Bool {
        switch kind {
        case .none:
            return false
        case .push, .modal, .fade, .magicMove, .custom:
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

    init(kind: Kind, presentation: ExperienceLayerPresentation = .modalDefault, presentationIsSupported: Bool = true, transitionId: String? = nil) {
        self.kind = kind
        if case .custom(let id) = kind { self.transitionId = id }
        else { self.transitionId = transitionId }
        self.presentation = presentation
        self.presentationIsSupported = presentationIsSupported
    }

    init(raw: Any?, sourceScreenID: String? = nil) {
        guard var record = ExperienceScreenTransitionSpec.transitionRecord(from: raw) else {
            self = .none
            return
        }

        if let ids = record["transitionIds"] as? [String: String] {
            guard let sourceScreenID, let id = ids[sourceScreenID] else { self = .none; return }
            record["transitionId"] = id
        }
        let kind = ExperienceScreenTransitionSpec.kind(from: record)
        self.init(kind: kind, presentation: kind == .modal ? ExperienceLayerPresentation(
            kind: (record["present"] as? String).flatMap(ExperienceLayerPresentation.Kind.init(rawValue:)) ?? .sheet,
            height: (record["height"] as? String).flatMap(ExperienceLayerPresentation.Height.init(rawValue:)) ?? .large,
            closedBy: (record["closedby"] as? String).flatMap(ExperienceLayerPresentation.ClosedBy.init(rawValue:)) ?? .any
        ) : .modalDefault, presentationIsSupported: kind != .modal || record["present"] == nil
            || (record["present"] as? String).flatMap(ExperienceLayerPresentation.Kind.init(rawValue:)) != nil, transitionId: (record["transitionId"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            })
    }

    /// Page Back uses history at execution time. A fade with no published transition ID has no compiled step.
    static func pageTransition(raw: Any?, sourceScreenID: String, isBack: Bool,
                               inferredBack: Self = .none,
                               diagnostic: (String) -> Void = { LogWarning("\($0, privacy: .publicValue)") }) -> Self {
        let authored = Self(raw: raw, sourceScreenID: sourceScreenID)
        if isBack {
            if transitionRecord(from: raw) != nil {
                diagnostic("Experience page: ignoring Back transition; using page history")
            }
            return inferredBack
        }
        if authored.kind == .fade, authored.transitionId == nil {
            diagnostic("Experience page: fade without a published transition ID uses a cut")
            return .none
        }
        return authored
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
        case "magic-move", "custom":
            guard
                let rawTransitionId = record["transitionId"] as? String,
                !rawTransitionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .none
            }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "magic-move"
                ? .magicMove : .custom(transitionId: rawTransitionId)
        default:
            // Unknown kinds fall back to an instant transition.
            return .none
        }
    }

}
