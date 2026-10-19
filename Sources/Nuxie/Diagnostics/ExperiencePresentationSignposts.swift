import Foundation
import NuxieRuntime
import os

/// Mirrors presentation trace stages into os_signpost intervals, then passes
/// every stage on to `downstream` when that recorder is enabled.
///
/// A "Show" interval runs from the public trigger call to the first presented
/// drawable, and each traced piece of work (routing, artifact acquisition,
/// runtime preparation, display presentation) gets its own interval. The end
/// message carries the trace's own duration in milliseconds: a presented
/// drawable reports a presentation time the signpost clock cannot backdate to.
///
/// While signposts are enabled the trace runs even when `downstream` is
/// disabled: a few records per show, against work measured in milliseconds.
final class ExperiencePresentationSignposts: @unchecked Sendable {
    private struct OpenInterval {
        let attemptId: String
        let work: ExperiencePresentationWork
        let state: OSSignpostIntervalState
    }

    private let downstream: ExperiencePresentationTraceRecording
    private let signposter: OSSignposter
    private let lock = NSLock()
    private var shows: [String: OSSignpostIntervalState] = [:]
    private var work: [String: OpenInterval] = [:]

    init(
        downstream: ExperiencePresentationTraceRecording,
        signposter: OSSignposter = NuxieSignposts.signposter
    ) {
        self.downstream = downstream
        self.signposter = signposter
    }

    private func beginShow(_ attempt: ExperiencePresentationAttempt) {
        let state = signposter.beginInterval(
            "Show",
            id: signposter.makeSignpostID(),
            "\(attempt.triggerEvent, privacy: .public)"
        )
        lock.withLock { shows[attempt.id] = state }
    }

    private func endShow(
        _ attempt: ExperiencePresentationAttempt,
        outcome: String,
        at timestamp: ExperiencePresentationTimestamp
    ) {
        let state = lock.withLock { () -> OSSignpostIntervalState? in
            work = work.filter { $0.value.attemptId != attempt.id }
            return shows.removeValue(forKey: attempt.id)
        }
        guard let state else { return }
        let milliseconds = attempt.startedAtMonotonicTime.map {
            max(0, (timestamp.monotonicTime - $0) * 1_000)
        } ?? -1
        signposter.endInterval(
            "Show",
            state,
            "\(outcome, privacy: .public) \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms"
        )
    }

    private func beginWork(
        spanId: String,
        work kind: ExperiencePresentationWork,
        attempt: ExperiencePresentationAttempt,
        attributes: [String: String]
    ) {
        let id = signposter.makeSignpostID()
        let detail = Self.describe(attributes)
        let state: OSSignpostIntervalState
        switch kind {
        case .triggerRouting:
            state = signposter.beginInterval("Trigger routing", id: id, "\(detail, privacy: .public)")
        case .experienceResolution:
            state = signposter.beginInterval("Experience resolution", id: id, "\(detail, privacy: .public)")
        case .artifactAcquisition:
            state = signposter.beginInterval("Artifact acquisition", id: id, "\(detail, privacy: .public)")
        case .externalAssetPreparation:
            state = signposter.beginInterval("External asset preparation", id: id, "\(detail, privacy: .public)")
        case .descriptorAuthentication:
            state = signposter.beginInterval("Descriptor authentication", id: id, "\(detail, privacy: .public)")
        case .storeKitProductLookup:
            state = signposter.beginInterval("StoreKit product lookup", id: id, "\(detail, privacy: .public)")
        case .runtimePreparation:
            state = signposter.beginInterval("Runtime preparation", id: id, "\(detail, privacy: .public)")
        case .displayPresentation:
            state = signposter.beginInterval("Display presentation", id: id, "\(detail, privacy: .public)")
        }
        lock.withLock {
            work[spanId] = OpenInterval(attemptId: attempt.id, work: kind, state: state)
        }
    }

    private func endWork(
        spanId: String,
        outcome: String,
        durationMilliseconds: Double,
        attributes: [String: String]
    ) {
        guard let open = lock.withLock({ work.removeValue(forKey: spanId) }) else {
            return
        }
        let state = open.state
        let detail = Self.describe(attributes)
        switch open.work {
        case .triggerRouting:
            signposter.endInterval("Trigger routing", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .experienceResolution:
            signposter.endInterval("Experience resolution", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .artifactAcquisition:
            signposter.endInterval("Artifact acquisition", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .externalAssetPreparation:
            signposter.endInterval("External asset preparation", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .descriptorAuthentication:
            signposter.endInterval("Descriptor authentication", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .storeKitProductLookup:
            signposter.endInterval("StoreKit product lookup", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .runtimePreparation:
            signposter.endInterval("Runtime preparation", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        case .displayPresentation:
            signposter.endInterval("Display presentation", state, "\(outcome, privacy: .public) \(durationMilliseconds, format: .fixed(precision: 2), privacy: .public) ms \(detail, privacy: .public)")
        }
    }

    private func milestone(_ name: String) {
        signposter.emitEvent("Presentation milestone", "\(name, privacy: .public)")
    }

    private static func describe(_ attributes: [String: String]) -> String {
        attributes.keys.sorted().map { "\($0)=\(attributes[$0] ?? "")" }
            .joined(separator: " ")
    }
}

extension ExperiencePresentationSignposts: ExperiencePresentationTraceRecording {
    var isEnabled: Bool { downstream.isEnabled || signposter.isEnabled }

    func record(
        attempt: ExperiencePresentationAttempt,
        stage: ExperiencePresentationTraceStage,
        timestamp: ExperiencePresentationTimestamp
    ) {
        if downstream.isEnabled {
            downstream.record(attempt: attempt, stage: stage, timestamp: timestamp)
        }
        guard signposter.isEnabled else { return }
        switch stage {
        case .triggerAccepted:
            beginShow(attempt)
        case .workStarted(let spanId, let work, let attributes):
            beginWork(spanId: spanId, work: work, attempt: attempt, attributes: attributes)
        case .workCompleted(let spanId, _, let duration, let attributes):
            endWork(spanId: spanId, outcome: "completed", durationMilliseconds: duration, attributes: attributes)
        case .workFailed(let spanId, _, let duration, let errorCode, let attributes):
            endWork(spanId: spanId, outcome: "failed \(errorCode)", durationMilliseconds: duration, attributes: attributes)
        case .firstPresentedDrawable(let screenId, let frameNumber, _, _, _):
            milestone("first presented drawable \(screenId) frame \(frameNumber)")
            endShow(attempt, outcome: "presented", at: timestamp)
        case .presentationFailed(_, let errorCode):
            endShow(attempt, outcome: "failed \(errorCode)", at: timestamp)
        case .presentationAbandoned(_, let reason):
            endShow(attempt, outcome: "abandoned \(reason)", at: timestamp)
        case .presentationCleanupCompleted:
            endShow(attempt, outcome: "cleaned up", at: timestamp)
        case .eventTracked:
            milestone("event tracked")
        case .journeyMatched(let journeyId):
            milestone("journey matched \(journeyId)")
        case .presentationRequested(let versionId, _):
            milestone("presentation requested \(versionId)")
        case .runtimeReady:
            milestone("runtime ready")
        case .shellPresented:
            milestone("shell presented")
        case .revealed:
            milestone("revealed")
        case .firstAcceptedInput:
            milestone("first accepted input")
        }
    }
}
