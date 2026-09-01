import Foundation

/// A retry record is removed only after the event log durably accepts its
/// stable ID. Concurrent drainers and crashes between capture and journal
/// acknowledgement replay that same ID through EventLog's existing dedupe.
struct DeviceLegReporter {
    let journal: DeviceLegRunJournal
    let events: any RoutedStableSystemEventCapturing

    func flushPending() async throws {
        for run in try await journal.runs() {
            if !run.startedQueued {
                guard await queue(run, completion: false) else { continue }
                try await journal.markStartedQueued(run)
            }
            if run.completion != nil {
                guard await queue(run, completion: true) else { continue }
                try await journal.markCompletionQueued(run)
            }
        }
    }

    private func queue(_ run: DeviceLegRun, completion: Bool) async -> Bool {
        var properties: [String: Any] = [
            "journey_id": run.journeyId,
            "experience_id": run.reference.experienceId,
            "experience_version_id": run.reference.versionId,
            "leg_id": run.reference.legId,
            "leg_generation": run.generation,
            "started_at": Self.timestamp(run.startedAt),
        ]
        if completion, let result = run.completion {
            properties["completed_at"] = Self.timestamp(result.at)
            properties["outcome"] = result.outcome
            guard let data = try? ExactJSONCodec.encode(run.outputs),
                  let outputs = try? JSONSerialization.jsonObject(with: data) else { return false }
            properties["outputs"] = outputs
        }
        // Terminal beforeSend drops are also durable acknowledgements. Host
        // privacy policy must not create an immortal retry record.
        guard let _ = await events.captureAndRouteSystemEvent(
            completion ? JourneyEvents.journeyLegCompleted : JourneyEvents.journeyLegStarted,
            properties: properties,
            eventId: completion ? run.completedEventId : run.startedEventId,
            distinctId: journal.distinctId
        ) else { return false }
        return true
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension DeviceLegReporter: Sendable {}
