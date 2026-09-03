import Foundation

/// A retry record is removed only after the event log durably accepts its
/// stable ID. Concurrent drainers and crashes between capture and journal
/// acknowledgement replay that same ID through EventLog's existing dedupe.
struct JourneyReporter {
    let journal: JourneyRunJournal
    let events: any RoutedStableSystemEventCapturing

    func flushPending() async throws {
        for run in try await journal.runs() {
            if !run.startedQueued {
                guard await queue(run, completion: false) else { continue }
                try await journal.markStartedQueued(run)
            }
            if run.completion != nil {
                // A shown experiment decision owns its exposure record before
                // the terminal run can be removed from the journal.
                guard !run.experimentExposures.contains(where: {
                    $0.shownAt != nil && !$0.queued
                }) else { continue }
                guard await queue(run, completion: true) else { continue }
                try await journal.markCompletionQueued(run)
            }
        }
    }

    private func queue(_ run: JourneyRun, completion: Bool) async -> Bool {
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
        guard let _ = await events.captureAndRouteSystemEvent(.init(
            name: completion
                ? JourneyEvents.journeyCompleted
                : JourneyEvents.journeyStarted,
            properties: properties,
            eventId: completion ? run.completedEventId : run.startedEventId,
            distinctId: journal.distinctId
        )) else { return false }
        return true
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension JourneyReporter: Sendable {}

/// Flushes only experiment decisions whose selected variant reached a visible
/// surface. The journal keeps the stable event ID until EventLog accepts it,
/// so a crash or transient storage failure cannot duplicate an exposure.
struct JourneyExperimentExposureReporter: Sendable {
    private struct Projection {
        let eventName: String
        let properties: [String: Any]
    }

    let journal: JourneyRunJournal
    let events: any RoutedStableSystemEventCapturing

    func flushPending(
        admission: JourneyCommitAdmission? = nil
    ) async throws -> Bool {
        for run in try await journal.runs() {
            for exposure in run.experimentExposures
            where exposure.shownAt != nil && !exposure.queued {
                let projection = projection(exposure, run: run)
                let capture = await captureStableSystemEvent(
                    projection.eventName,
                    properties: projection.properties,
                    eventId: exposure.eventId,
                    admission: admission
                )
                guard capture != nil else { return false }
                guard await events.drainCommittedRouting() else {
                    return false
                }
                try await journal.markExperimentExposureQueued(
                    run.id,
                    eventId: exposure.eventId
                )
            }
        }
        return true
    }

    private func captureStableSystemEvent(
        _ name: String,
        properties: sending [String: Any],
        eventId: String,
        admission: JourneyCommitAdmission?
    ) async -> DurableTriggerCapture? {
        let request = StableSystemEventCaptureRequest(
            name: name,
            properties: properties,
            eventId: eventId,
            distinctId: journal.distinctId
        )
        if let admission {
            return await events.captureAndRouteSystemEvent(
                request,
                admission: admission
            )
        }
        return await events.captureAndRouteSystemEvent(request)
    }

    private func projection(
        _ exposure: JourneyRun.ExperimentExposure,
        run: JourneyRun
    ) -> Projection {
        var properties: [String: Any] = [
            "journey_id": run.journeyId,
            "experience_id": run.reference.experienceId,
            "experience_version": run.reference.versionId,
            "leg_id": run.reference.legId,
            "leg_generation": run.generation,
            "experiment_key": exposure.experimentId,
            "variant_key": exposure.variantId,
        ]
        properties["assignment_source"] = exposure.kind == .assigned
            ? "profile"
            : "fallback"
        switch exposure.kind {
        case .assigned:
            properties["is_holdout"] = exposure.isHoldout
        case .fallback:
            properties["is_holdout"] = false
        }
        return Projection(
            eventName: JourneyEvents.experimentExposure,
            properties: properties
        )
    }
}
