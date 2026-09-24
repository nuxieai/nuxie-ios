import Foundation

/// Projects only committed Journey answers into the response bindings declared by
/// each screen. Unset restores that screen's authored, correctly typed default.
struct JourneyResponseViewModelProjection {
    private let screens: [Journey.Screen]
    private let defaults: [JourneyViewModelValue]
    private var answers: ExactJSONObject<AnyCodable>

    init(screens: [Journey.Screen], defaults: [JourneyViewModelValue],
         answers: ExactJSONObject<JourneyReleaseJSONValue> = [:]) {
        self.screens = screens
        self.defaults = defaults
        self.answers = [:]
        for (field, value) in answers {
            guard let data = try? JSONEncoder().encode(value),
                  let converted = try? JSONDecoder().decode(AnyCodable.self, from: data) else { continue }
            self.answers[field] = converted
        }
    }

    /// Call only after the journal acknowledges the batch. Renderer intent is
    /// not authority to update either the retained answers or visible bindings.
    mutating func accept(_ emissions: [ScreenEmission]) -> Set<String> {
        var changed: Set<String> = []
        for emission in emissions {
            guard case .string(let field) = emission.payload["field"] else { continue }
            switch emission.name {
            case JourneyResponseControlNames.responseSet:
                guard let value = emission.payload["value"],
                      let data = try? JSONEncoder().encode(value),
                      let converted = try? JSONDecoder().decode(AnyCodable.self, from: data) else { continue }
                answers[field] = converted
            case JourneyResponseControlNames.responseUnset:
                answers[field] = nil
            default:
                continue
            }
            changed.insert(field)
        }
        return changed
    }

    func values(screenID: String, fields: Set<String>? = nil) -> [JourneyViewModelValue] {
        guard let screen = screens.first(where: { $0.id == screenID }),
              let model = screen.defaultViewModelName else { return [] }
        let prefix = "response/values/"
        return defaults.compactMap { original in
            guard original.viewModelName == model,
                  original.instanceId == screen.defaultInstanceId,
                  original.path.hasPrefix(prefix) else { return nil }
            let field = String(original.path.dropFirst(prefix.count))
            guard fields?.contains(field) != false else { return nil }
            return JourneyViewModelValue(viewModelName: original.viewModelName,
                instanceId: original.instanceId, instanceName: original.instanceName,
                path: original.path, value: answers[field] ?? original.value)
        }
    }
}
