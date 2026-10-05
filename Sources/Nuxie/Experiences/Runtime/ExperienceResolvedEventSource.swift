#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

/// The values Rive reported for this occurrence in the event's frame.
/// Native identities are process-local and must never enter the run journal.
struct ExperienceResolvedEventSource: Equatable, Sendable {
    let nativeID: UInt64
    let snapshot: ExperienceInteractiveViewModelSnapshot
    let schemaNames: [Int: String]
}

/// Aligns ordinary drafts and control output with their own frame sources.
struct ExperienceEmissionSources: Sendable {
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

/// Retains frame values beside a batch until its invocation is admitted.
final class ExperienceEventSources: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [String: ExperienceEmissionSources] = [:]

    func put(_ source: ExperienceEmissionSources?, invocationID: String) {
        lock.withLock { sources[invocationID] = source }
    }

    func take(invocationID: String) -> ExperienceEmissionSources? {
        lock.withLock { sources.removeValue(forKey: invocationID) }
    }
}
#endif
