#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

/// The values Rive reported for this occurrence in the event's frame.
/// Native identities are process-local and must never enter the run journal.
struct ExperienceResolvedEventSource: Equatable, Sendable {
    let nativeID: UInt64
    let snapshot: ExperienceInteractiveViewModelSnapshot
    let schemaNames: [Int: String]

    func string(path: VmPathRef) -> String? {
        guard let instance = snapshot.instances.first(where: { $0.id == nativeID }),
              path.viewModelName == nil || path.viewModelName == schemaNames[instance.schemaIndex] else {
            return nil
        }
        let segments = path.path.split(whereSeparator: { $0 == "/" || $0 == "." }).map(String.init)
        guard let last = segments.last else { return nil }
        var ownerID = nativeID
        for segment in segments.dropLast() {
            guard let field = snapshot.values.first(where: {
                $0.ownerInstanceID == ownerID && $0.name == segment
            }), case .referencedInstance(let nextID) = field.value,
            snapshot.instances.contains(where: { $0.id == nextID }) else { return nil }
            ownerID = nextID
        }
        guard let field = snapshot.values.first(where: {
            $0.ownerInstanceID == ownerID && $0.name == last
        }), case .bytes(let bytes) = field.value else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}

/// Aligns ordinary drafts and control output with their own frame sources.
struct ExperienceEmissionSources: Sendable {
    var frameLinks: ExperienceFrameLinks?
    var control: ExperienceResolvedEventSource?
    var drafts: [ExperienceResolvedEventSource?] = []
    var byEmissionID: [String: ExperienceResolvedEventSource] = [:]

    func bound(to batch: ScreenEmissionBatch) -> Self {
        var result = self
        let controlCount = batch.emissions.count - drafts.count
        for (index, emission) in batch.emissions.enumerated() {
            let source = index < controlCount ? control : drafts[index - controlCount]
            result.byEmissionID[emission.id] = source
        }
        return result
    }

    func source(eventID: String?) -> ExperienceResolvedEventSource? {
        guard let eventID else { return control }
        return byEmissionID[eventID]
    }
}

/// One frame owns one handoff, including rejected publication and link-only frames.
@MainActor
final class ExperienceFrameLinks {
    private var operation: (@MainActor () async -> Void)?
    init(_ operation: @escaping @MainActor () async -> Void) { self.operation = operation }
    func perform() async {
        let operation = self.operation
        self.operation = nil
        await operation?()
    }
}

#endif
