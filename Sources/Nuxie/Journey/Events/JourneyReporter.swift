import Foundation

/// Pure projections prepared through the ordinary event privacy pipeline before SQL.
enum JourneyReporter {
    static func started(_ journey: JourneyRun, owner: String) throws -> RoutedStableSystemEventBatchItem {
        .init(request: .init(name: JourneyEvents.journeyStarted, properties: properties(journey),
            eventId: journey.startedEventId, distinctId: owner), occurredAt: journey.startedAt)
    }

    static func completed(_ journey: JourneyRun, owner: String, outcome: String, at: Date,
                          outputs: ArmedJourney.Context) throws -> RoutedStableSystemEventBatchItem {
        var values = properties(journey)
        values["completed_at"] = timestamp(at)
        values["outcome"] = outcome
        values["outputs"] = try JSONSerialization.jsonObject(with: ExactJSONCodec.encode(outputs))
        return .init(request: .init(name: JourneyEvents.journeyCompleted, properties: values,
            eventId: journey.completedEventId, distinctId: owner), occurredAt: at)
    }

    static func exposure(_ exposure: JourneyRun.ExperimentExposure, journey: JourneyRun,
                         owner: String, at: Date) throws -> RoutedStableSystemEventBatchItem {
        let values: [String: Any] = [
            "journey_id": journey.journeyId, "experience_id": journey.reference.experienceId,
            "experience_version": journey.reference.versionId, "leg_id": journey.reference.legId,
            "leg_generation": journey.generation, "experiment_key": exposure.experimentId,
            "variant_key": exposure.variantId, "assignment_source": exposure.kind == .assigned ? "profile" : "fallback",
            "is_holdout": exposure.isHoldout,
        ]
        return .init(request: .init(name: JourneyEvents.experimentExposure, properties: values,
            eventId: exposure.eventId, distinctId: owner), occurredAt: at)
    }

    private static func properties(_ journey: JourneyRun) -> [String: Any] {
        ["journey_id": journey.journeyId, "experience_id": journey.reference.experienceId,
         "experience_version_id": journey.reference.versionId, "leg_id": journey.reference.legId,
         "leg_generation": journey.generation, "started_at": timestamp(journey.startedAt)]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
