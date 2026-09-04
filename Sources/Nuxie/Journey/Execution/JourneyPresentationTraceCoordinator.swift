import Foundation

/// Process-local correlation for presentation diagnostics. Events still enter
/// Journeys through EventLog's single durable subscriber lane; this coordinator
/// only carries an opaque trace attempt alongside that ordinary event identity.
final class JourneyPresentationTraceCoordinator: @unchecked Sendable {
    private struct State {
        var qualificationAttempt: ExperiencePresentationAttempt?
        var qualificationTriggerClaimed = false
        var restoredAttempt: ExperiencePresentationAttempt?
        var restoredRunClaimed = false
        var eventAttempts: [String: ExperiencePresentationAttempt] = [:]
        var eventOrder: [String] = []
        var runAttempts: [String: ExperiencePresentationAttempt] = [:]
        var matchedRuns: Set<String> = []
        var completedRoutingAttempts: Set<String> = []
    }

    private let lock = NSLock()
    private let recorder: ExperiencePresentationTraceRecording
    private var state: State
    private static let maximumPendingEvents = 256

    init(
        recorder: ExperiencePresentationTraceRecording,
        qualificationAttempt: ExperiencePresentationAttempt? = nil,
        restoredAttempt: ExperiencePresentationAttempt? = nil
    ) {
        self.recorder = recorder
        state = State(
            qualificationAttempt: qualificationAttempt,
            restoredAttempt: restoredAttempt
        )
    }

    var isEnabled: Bool { recorder.isEnabled }

    func beginTrigger(
        event: String,
        at timestamp: ExperiencePresentationTimestamp
    ) -> (eventId: String, attempt: ExperiencePresentationAttempt)? {
        guard recorder.isEnabled else { return nil }
        let eventId = UUID.v7().uuidString
        let selection = lock.withLock { () -> (ExperiencePresentationAttempt, Bool) in
            let attempt: ExperiencePresentationAttempt
            let needsStartRecord: Bool
            if let qualificationAttempt = state.qualificationAttempt,
               qualificationAttempt.triggerEvent == event,
               !state.qualificationTriggerClaimed {
                state.qualificationTriggerClaimed = true
                attempt = qualificationAttempt
                needsStartRecord = false
            } else {
                attempt = ExperiencePresentationAttempt.make(
                    triggerEvent: event,
                    startedAt: timestamp.wallClock,
                    startedAtMonotonicTime: timestamp.monotonicTime
                )
                needsStartRecord = true
            }
            state.eventAttempts[eventId] = attempt
            state.eventOrder.append(eventId)
            while state.eventOrder.count > Self.maximumPendingEvents {
                let discarded = state.eventOrder.removeFirst()
                state.eventAttempts.removeValue(forKey: discarded)
            }
            return (attempt, needsStartRecord)
        }
        if selection.1 {
            ExperiencePresentationTraceContext(
                attempt: selection.0,
                recorder: recorder
            ).recordTriggerAcceptedAndBeginRouting(at: timestamp)
        }
        return (eventId, selection.0)
    }

    func consumeEvent(
        id: String,
        at timestamp: ExperiencePresentationTimestamp
    ) -> ExperiencePresentationAttempt? {
        let attempt = lock.withLock { () -> ExperiencePresentationAttempt? in
            state.eventOrder.removeAll { $0 == id }
            return state.eventAttempts.removeValue(forKey: id)
        }
        if let attempt {
            recorder.record(
                attempt: attempt,
                stage: .eventTracked(eventId: id),
                timestamp: timestamp
            )
        }
        return attempt
    }

    func bind(
        _ attempt: ExperiencePresentationAttempt,
        toRunId runId: String,
        journeyId: String,
        at timestamp: ExperiencePresentationTimestamp
    ) {
        let shouldRecord = lock.withLock { () -> Bool in
            state.runAttempts[runId] = attempt
            return state.matchedRuns.insert(runId).inserted
        }
        if shouldRecord {
            recorder.record(
                attempt: attempt,
                stage: .journeyMatched(journeyId: journeyId),
                timestamp: timestamp
            )
        }
    }

    func beginPresentation(
        runId: String,
        journeyId: String,
        experienceVersionId: String,
        at timestamp: ExperiencePresentationTimestamp
    ) -> ExperiencePresentationTraceContext? {
        guard recorder.isEnabled else { return nil }
        let selection = lock.withLock {
            () -> (ExperiencePresentationAttempt?, Bool) in
            if let attempt = state.runAttempts[runId] {
                return (attempt, false)
            }
            guard let attempt = state.restoredAttempt,
                  !state.restoredRunClaimed else {
                return (nil, false)
            }
            state.restoredRunClaimed = true
            state.runAttempts[runId] = attempt
            return (attempt, state.matchedRuns.insert(runId).inserted)
        }
        guard let attempt = selection.0 else { return nil }
        if selection.1 {
            recorder.record(
                attempt: attempt,
                stage: .journeyMatched(journeyId: journeyId),
                timestamp: timestamp
            )
        }
        let context = ExperiencePresentationTraceContext(
            attempt: attempt,
            recorder: recorder
        )
        context.recordPresentationRequested(
            experienceVersionId: experienceVersionId,
            route: .journey,
            at: timestamp
        )
        _ = lock.withLock {
            state.completedRoutingAttempts.insert(attempt.id)
        }
        return context
    }

    func completeRouting(
        _ attempt: ExperiencePresentationAttempt,
        at timestamp: ExperiencePresentationTimestamp
    ) {
        let shouldComplete = lock.withLock {
            state.completedRoutingAttempts.insert(attempt.id).inserted
        }
        guard shouldComplete else { return }
        ExperiencePresentationTraceContext(
            attempt: attempt,
            recorder: recorder
        ).completeTriggerRouting(at: timestamp)
    }
}
