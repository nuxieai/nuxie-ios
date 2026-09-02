import Foundation

/// Serializes renderer-authored event publication with the owning identity and
/// execution fences. Direct-route markers prevent EventLog subscribers from
/// racing the renderer callback that owns the same run transition.
actor DeviceLegPresentationPublicationCoordinator {
    struct BatchPublication: Sendable {
        let captures: [String: DurableTriggerCapture]
        let remainsAuthorized: Bool
        let admission: DeviceLegCommitAdmission
    }

    private let identity: IdentityServiceProtocol
    private let events: any RoutedStableSystemEventCapturing
    private let executionFence: DeviceLegProfileFence
    private var directlyRoutedRunByEventId: [String: String] = [:]

    init(
        identity: IdentityServiceProtocol,
        events: any RoutedStableSystemEventCapturing,
        executionFence: DeviceLegProfileFence
    ) {
        self.identity = identity
        self.events = events
        self.executionFence = executionFence
    }

    func consumeDirectRoute(eventId: String) -> String? {
        directlyRoutedRunByEventId.removeValue(forKey: eventId)
    }

    func clearDirectRoutes() {
        directlyRoutedRunByEventId.removeAll()
    }

    func publish(
        _ items: [RoutedStableSystemEventBatchItem],
        forRunId runId: String,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchPublication? {
        guard let identityFence = identity.performWithCurrentIdentityFence(
            journal.distinctId,
            { _ in () }
        ) else { return nil }
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
        for item in items {
            directlyRoutedRunByEventId[item.eventId] = runId
        }
        guard let captures = await events.captureAndRouteSystemEventBatch(
            items,
            admission: admission
        ) else {
            removeDirectRoutes(items, runId: runId)
            return nil
        }

        // Existing captures and terminal beforeSend drops do not enqueue
        // subscriber work. Newly routed markers remain until either the route
        // worker drains or its nested callback consumes the marker.
        for item in items {
            guard let capture = captures[item.eventId],
                  capture.routesLocally,
                  capture.isNewlyCommitted else {
                removeDirectRoute(eventId: item.eventId, runId: runId)
                continue
            }
        }
        if await events.drainCommittedRouting() {
            removeDirectRoutes(items, runId: runId)
        }
        guard items.allSatisfy({ captures[$0.eventId] != nil }) else {
            return nil
        }
        let executionRemainsAuthorized = executionFence.isCurrent(
            executionFenceToken
        )
        let identityRemainsAuthorized = await isCurrentIdentity(
            identityFence.token,
            journal: journal
        )
        let remainsAuthorized = executionRemainsAuthorized
            && identityRemainsAuthorized
        return BatchPublication(
            captures: captures,
            remainsAuthorized: remainsAuthorized,
            admission: admission
        )
    }

    func capture(
        name: String,
        properties: UncheckedSendable<[String: Any]>,
        eventId: String,
        occurredAt: Date,
        forRunId runId: String,
        in journal: DeviceLegRunJournal,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> DurableTriggerCapture? {
        guard executionFence.isCurrent(executionFenceToken),
              await isCurrentIdentity(
                identityFenceToken,
                journal: journal
              ) else { return nil }
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFenceToken,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
        directlyRoutedRunByEventId[eventId] = runId
        let capture = await events.captureAndRouteSystemEvent(
            name,
            properties: properties.value,
            eventId: eventId,
            distinctId: journal.distinctId,
            occurredAt: occurredAt,
            admission: admission
        )
        let routingDrained = await events.drainCommittedRouting()
        let routeWillReachSubscribers = capture?.routesLocally == true
            && capture?.isNewlyCommitted == true
        if !routeWillReachSubscribers || routingDrained {
            removeDirectRoute(eventId: eventId, runId: runId)
        }
        guard let capture,
              executionFence.isCurrent(executionFenceToken),
              await isCurrentIdentity(
                identityFenceToken,
                journal: journal
              ) else {
            return nil
        }
        return capture
    }

    func flushPending(
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async throws {
        for run in try await journal.runs() {
            guard let pending = run.pendingPresentationPublication else {
                continue
            }
            guard let items = DeviceLegPresentationEventProjector.routedItems(
                pending.items,
                distinctId: journal.distinctId
            ) else {
                throw DeviceLegJournalError.invalidState
            }
            let admission: DeviceLegCommitAdmission
            if items.isEmpty {
                guard let identityFence = identity
                    .performWithCurrentIdentityFence(
                        journal.distinctId,
                        { _ in () }
                    ) else {
                    throw DeviceLegJournalError.invalidState
                }
                admission = DeviceLegCommitAdmission(
                    identity: identity,
                    identityFenceToken: identityFence.token,
                    executionFence: executionFence,
                    executionFenceToken: executionFenceToken
                )
            } else {
                guard let publication = await publish(
                    items,
                    forRunId: run.id,
                    in: journal,
                    executionFenceToken: executionFenceToken
                ), publication.remainsAuthorized else {
                    throw DeviceLegJournalError.invalidState
                }
                admission = publication.admission
            }
            guard try await journal.clearPresentationPublication(
                run.id,
                invocationId: pending.invocationId,
                admission: admission
            ) else {
                throw DeviceLegJournalError.invalidState
            }
        }
    }

    private func removeDirectRoutes(
        _ items: [RoutedStableSystemEventBatchItem],
        runId: String
    ) {
        for item in items {
            removeDirectRoute(eventId: item.eventId, runId: runId)
        }
    }

    private func removeDirectRoute(eventId: String, runId: String) {
        guard directlyRoutedRunByEventId[eventId] == runId else { return }
        directlyRoutedRunByEventId.removeValue(forKey: eventId)
    }

    private func isCurrentIdentity(
        _ token: IdentityFenceToken,
        journal: DeviceLegRunJournal
    ) async -> Bool {
        guard identity.getDistinctId() == journal.distinctId else {
            return false
        }
        return await MainActor.run {
            identity.publishIfCurrentIdentityFenceToken(token) {}
        }
    }
}

enum DeviceLegPresentationEventProjector {
    static func properties(
        payload: ExactJSONObject<ExperienceReleaseJSONValue>,
        screenId: String,
        run: DeviceLegRun
    ) -> [String: Any]? {
        foundationValues(values(
            payload: payload,
            screenId: screenId,
            run: run
        ))
    }

    static func values(
        payload: ExactJSONObject<ExperienceReleaseJSONValue>,
        screenId: String,
        run: DeviceLegRun
    ) -> ExactJSONObject<ExperienceReleaseJSONValue> {
        var properties = payload
        properties["screen_id"] = .string(screenId)
        properties["journey_id"] = .string(run.journeyId)
        properties["experience_id"] = .string(run.reference.experienceId)
        properties["experience_version"] = .string(run.reference.versionId)
        properties["leg_id"] = .string(run.reference.legId)
        properties["leg_generation"] = .number(Double(run.generation))
        return properties
    }

    static func routedItems(
        _ items: [DeviceLegRun.PendingPresentationPublication.Item],
        distinctId: String
    ) -> [RoutedStableSystemEventBatchItem]? {
        var routed: [RoutedStableSystemEventBatchItem] = []
        routed.reserveCapacity(items.count)
        for item in items {
            guard let properties = foundationValues(item.properties) else {
                return nil
            }
            routed.append(.init(
                name: item.name,
                properties: properties,
                eventId: item.eventId,
                distinctId: distinctId,
                occurredAt: item.occurredAt
            ))
        }
        return routed
    }

    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private static func foundationValues(
        _ properties: ExactJSONObject<ExperienceReleaseJSONValue>
    ) -> [String: Any]? {
        guard let data = try? ExactJSONCodec.encode(properties) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
