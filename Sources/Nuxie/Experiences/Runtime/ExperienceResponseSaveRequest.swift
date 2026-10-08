#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// An immutable sheet captured from the frame that requested its save.
struct ExperienceResponseSaveRequest: Equatable, Sendable {
    let form: String
    let awaitTrigger: String?
    let answers: ExactJSONObject<JourneyReleaseJSONValue>

    static func capture(_ effect: ExperienceInteractiveEffectKind,
        snapshot: NuxieNativeViewModelSnapshot?, catalog: NuxieNativeViewModelCatalog,
        policy: JourneyReleaseValuePolicy
    ) throws -> Self? {
        let fields: [ExperienceInteractiveField]
        switch effect {
        case .reportedEvent(let event) where event.name == "$nuxie.response.save":
            guard event.url.isEmpty, event.sourceRejection == nil else { throw invalid }
            fields = event.properties
        case .hostCommand(let name, let payload) where name == "$nuxie.response.save",
             .journeyEvent(let name, let payload) where name == "$nuxie.response.save":
            guard case .object(let object) = payload else { throw invalid }
            fields = object
        default: return nil
        }
        guard Set(fields.map(\.key)).count == fields.count,
              let form = text(fields.first { $0.key == "form" }?.value),
              let declaration = policy.responses[form], let snapshot else { throw invalid }
        let trigger: String?
        if let field = fields.first(where: { $0.key == "awaitTrigger" }) {
            guard let path = text(field.value), !path.isEmpty else { throw invalid }
            trigger = path
        } else {
            trigger = nil
        }
        let root: UInt64
        if case .referencedInstance(let shared) = snapshot.values.first(where: {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "experience"
        })?.value {
            root = shared
        } else {
            root = snapshot.rootInstanceID
        }
        let answers = try ExperienceResponseSheet.read(form: form, declaration: declaration,
            snapshot: snapshot, catalog: catalog, experienceRoot: root)
        return Self(form: form, awaitTrigger: trigger, answers: answers)
    }

    private static func text(_ value: ExperienceInteractiveValue?) -> String? {
        switch value {
        case .string(let text): text
        case .bytes(let bytes): String(data: bytes, encoding: .utf8)
        default: nil
        }
    }

    private static var invalid: ExperienceInteractiveScreenError {
        .stateContract("Invalid native response save request")
    }
}
#endif
