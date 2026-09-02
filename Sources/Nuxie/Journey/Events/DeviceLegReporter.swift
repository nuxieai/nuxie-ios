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
        guard let _ = await events.captureAndRouteSystemEvent(.init(
            name: completion
                ? JourneyEvents.journeyLegCompleted
                : JourneyEvents.journeyLegStarted,
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

extension DeviceLegReporter: Sendable {}

/// Flushes only experiment decisions whose selected variant reached a visible
/// surface. The journal keeps the stable event ID until EventLog accepts it,
/// so a crash or transient storage failure cannot duplicate an exposure.
struct DeviceLegExperimentExposureReporter: Sendable {
    let journal: DeviceLegRunJournal
    let events: any RoutedStableSystemEventCapturing

    func flushPending(
        admission: DeviceLegCommitAdmission? = nil
    ) async throws -> Bool {
        for run in try await journal.runs() {
            for exposure in run.experimentExposures
            where exposure.shownAt != nil && !exposure.queued {
                let properties = properties(exposure, run: run)
                let capture: DurableTriggerCapture?
                switch exposure.kind {
                case .assigned:
                    capture = await captureStableSystemEvent(
                        JourneyEvents.experimentExposure,
                        properties: properties,
                        eventId: exposure.eventId,
                        admission: admission
                    )
                case .fallback:
                    capture = await captureStableSystemEvent(
                        JourneyEvents.experimentExposureFallback,
                        properties: properties,
                        eventId: exposure.eventId,
                        admission: admission
                    )
                case .invalidAssignment:
                    capture = await captureStableSystemEvent(
                        JourneyEvents.experimentExposureError,
                        properties: properties,
                        eventId: exposure.eventId,
                        admission: admission
                    )
                }
                guard capture != nil else { return false }
                await events.drainCommittedRouting()
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
        admission: DeviceLegCommitAdmission?
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

    private func properties(
        _ exposure: DeviceLegRun.ExperimentExposure,
        run: DeviceLegRun
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": run.journeyId,
            "experience_id": run.reference.experienceId,
            "experience_version": run.reference.versionId,
            "experiment_key": exposure.experimentId,
            "variant_key": exposure.variantId,
        ]
        switch exposure.kind {
        case .assigned:
            properties["assignment_source"] = "profile"
            properties["is_holdout"] = exposure.isHoldout
        case .fallback:
            properties["assignment_source"] = "no_assignment"
        case .invalidAssignment:
            properties["variant_key"] = exposure.assignedVariantId
                ?? exposure.variantId
            properties["reason"] = "variant_not_found"
        }
        return properties
    }
}
