import Foundation

/// Converts durable captures into host-facing activities while retaining the
/// small amount of journey context that is intentionally absent from journey
/// wire events. The event log routes captures through this actor in order.
actor ActivityForwardingPipeline {
    private static let maximumJourneyContexts = 256

    private var experiencesByJourneyId: [String: ExperienceRef] = [:]
    private var journeyIdsInRecencyOrder: [String] = []
    private let journeyContextResolver: (@Sendable (String) -> ExperienceRef?)?

    init(
        journeyContextResolver: (@Sendable (String) -> ExperienceRef?)? = nil
    ) {
        self.journeyContextResolver = journeyContextResolver
    }

    func activity(for capture: CommittedCapture) async -> NuxieActivity? {
        observeJourneyExperience(from: capture)
        let journeyId = ActivityCuration.journeyId(in: capture.event.properties)
        var journeyExperience = journeyId.flatMap { experiencesByJourneyId[$0] }
        if journeyExperience == nil,
           let journeyId,
           let resolver = journeyContextResolver,
           let resolved = resolver(journeyId) {
            // Live journeys restored after a relaunch are not replayed through
            // the committed stream; resolve their context on demand so their
            // summaries keep an experience identity, and retain it for the
            // journey's remaining activities.
            journeyExperience = resolved
            seedJourneyContexts([resolved])
        }
        return ActivityCuration.activity(
            canonicalName: capture.canonicalName,
            properties: capture.event.properties,
            journeyExperience: journeyExperience
        )
    }

    /// Seed journey context restored from durable journeys so summaries from
    /// resumed (for example parked) journeys keep their experience identity
    /// across process restarts. Wire events stay context-free.
    func seedJourneyContexts(_ contexts: [ExperienceRef]) {
        for experience in contexts {
            guard let journeyId = experience.journeyId else { continue }
            experiencesByJourneyId[journeyId] = experience
            journeyIdsInRecencyOrder.removeAll { $0 == journeyId }
            journeyIdsInRecencyOrder.append(journeyId)
            if journeyIdsInRecencyOrder.count > Self.maximumJourneyContexts {
                let evictedJourneyId = journeyIdsInRecencyOrder.removeFirst()
                experiencesByJourneyId.removeValue(forKey: evictedJourneyId)
            }
        }
    }

    private func observeJourneyExperience(from capture: CommittedCapture) {
        guard capture.canonicalName == JourneyEvents.journeyEnrolled
                || capture.canonicalName == JourneyEvents.experienceShown,
              let experience = ActivityCuration.observedJourneyExperienceRef(
                capture.event.properties
              ),
              let journeyId = experience.journeyId else {
            return
        }

        experiencesByJourneyId[journeyId] = experience
        journeyIdsInRecencyOrder.removeAll { $0 == journeyId }
        journeyIdsInRecencyOrder.append(journeyId)

        if journeyIdsInRecencyOrder.count > Self.maximumJourneyContexts {
            let evictedJourneyId = journeyIdsInRecencyOrder.removeFirst()
            experiencesByJourneyId.removeValue(forKey: evictedJourneyId)
        }
    }
}
