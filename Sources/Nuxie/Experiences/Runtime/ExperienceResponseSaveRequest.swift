#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import NuxieRuntime

/// An immutable sheet captured from the frame that requested its save.
struct ExperienceResponseSaveRequest: Equatable, Sendable {
    let form: String
    let awaitTrigger: String?
    let answers: ExactJSONObject<JourneyReleaseJSONValue>
    /// The values an awaited save keeps for what follows its `await`, as the
    /// screen held them when the save was requested. Each `keep:<value>`
    /// property names one in the screen's `state`. They are written back just
    /// before `awaitTrigger` fires, so what follows reads its own call's
    /// `$event` values though another call came first.
    var kept: [ExperienceRunSnapshot.Field] = []

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
        let keep = try fields.filter { $0.key.hasPrefix("keep:") }.map { field -> String in
            guard let path = text(field.value), path.hasPrefix("state/"),
                  path.dropFirst("state/".count).allSatisfy({ $0 != "/" }), path.count > "state/".count
            else { throw invalid }
            return path
        }
        guard keep.isEmpty || trigger != nil else { throw invalid }
        var kept: [ExperienceRunSnapshot.Field] = []
        if !keep.isEmpty {
            let held = ExperienceRunSnapshot.captureFields(native: snapshot, catalog: catalog,
                root: snapshot.rootInstanceID)
            kept = try keep.map { path in
                guard let field = held.first(where: { $0.path == path }) else { throw invalid }
                return field
            }
        }
        return Self(form: form, awaitTrigger: trigger, answers: answers, kept: kept)
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
