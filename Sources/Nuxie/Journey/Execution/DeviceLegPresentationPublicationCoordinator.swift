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

    struct BatchContinuation: Sendable {
        let run: DeviceLegRun
        let signal: DeviceLegControlExecutor.Signal
        let checkpoint: DeviceLegControlExecutor.Checkpoint?
    }

    struct BatchFailure: Sendable {
        let publishedOrdinaryEvents: Bool
        let run: DeviceLegRun
        let context: ArmedDeviceLeg.Context
    }

    enum BatchDisposition: Sendable {
        case rejected
        case accepted
        case continueExecution(BatchContinuation)
        case publicationFailed(BatchFailure)
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

    /// Commits one renderer invocation as a durable unit. Response mutations
    /// enter the run journal before ordinary events become visible, and the
    /// pending marker is cleared by the same transition that consumes a routed
    /// event. The service only owns presentation validation and the resulting
    /// run continuation or terminal recovery.
    func process(
        _ batch: ScreenEmissionBatch,
        for run: DeviceLegRun,
        leg: DeviceLeg,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchDisposition {
        let expectedStepId = run.stepId
        let expectedCheckpoint = Self.controlCheckpoint(from: run.park)
        let screenId = batch.source.screenId
        let responseCaptures = Set(
            leg.screens.first(where: { $0.id == screenId })?.responseCaptures
                ?? []
        )
        var stagedRun = run
        var responses = run.context.responses
        var responsesChanged = false
        var publicationItems: [
            DeviceLegRun.PendingPresentationPublication.Item
        ] = []
        publicationItems.reserveCapacity(batch.emissions.count)

        for emission in batch.emissions {
            if emission.name == SystemEventNames.responseSet {
                guard case .string(let field)? = emission.payload["field"],
                      let value = emission.payload["value"],
                      responseCaptures.contains(field) else {
                    return .rejected
                }
                responses[field] = value.releaseJSONValue
                responsesChanged = true
                continue
            }
            if emission.name == SystemEventNames.responseUnset {
                guard case .string(let field)? = emission.payload["field"],
                      responseCaptures.contains(field) else {
                    return .rejected
                }
                responses[field] = nil
                responsesChanged = true
                continue
            }
            guard let occurredAt = DeviceLegPresentationEventProjector.date(
                emission.occurredAt
            ), DeviceLegTime.milliseconds(occurredAt) != nil else {
                return .rejected
            }
            let properties = DeviceLegPresentationEventProjector.values(
                payload: ExactJSONObject(
                    emission.payload.mapValues(\.releaseJSONValue)
                ),
                screenId: screenId,
                run: run
            )
            publicationItems.append(.init(
                name: emission.name,
                properties: properties,
                eventId: emission.id,
                occurredAt: occurredAt
            ))
        }

        let context = ArmedDeviceLeg.Context(
            event: run.context.event,
            responses: responses
        )
        let publication = DeviceLegRun.PendingPresentationPublication(
            invocationId: batch.invocationId,
            source: batch.source,
            context: context,
            responsesChanged: responsesChanged,
            items: publicationItems
        )
        do {
            guard let admission = commitAdmission(
                in: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.stagePresentationPublication(
                run.id,
                expectedStepId: expectedStepId,
                expectedCheckpoint: expectedCheckpoint,
                publication: publication,
                admission: admission
            ) else { return .rejected }
        } catch {
            LogWarning(
                "DeviceLegPresentationPublicationCoordinator: failed to stage renderer publication: \(error)"
            )
            return .rejected
        }
        stagedRun.context = context
        return await settle(
            publication,
            for: stagedRun,
            leg: leg,
            in: journal,
            executionFenceToken: executionFenceToken
        )
    }

    /// Replays a renderer outbox through the same authenticated route and
    /// transition path as a live invocation. The marker remains durable until
    /// its event or response signal is applied to the owning run.
    func recover(
        _ run: DeviceLegRun,
        leg: DeviceLeg,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchDisposition {
        guard let publication = run.pendingPresentationPublication else {
            return .accepted
        }
        return await settle(
            publication,
            for: run,
            leg: leg,
            in: journal,
            executionFenceToken: executionFenceToken
        )
    }

    /// Publishes renderer events retained across a process break after the
    /// owning run has already become terminal. The ordinary event pipeline
    /// still observes the stable captures, while no screen route can mutate
    /// the completed run.
    func recoverObservability(
        _ run: DeviceLegRun,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> Bool {
        guard let publication = run.pendingPresentationPublication,
              let ordinaryItems = DeviceLegPresentationEventProjector
                .routedItems(
                    publication.items,
                    distinctId: journal.distinctId
                ) else { return false }
        guard !ordinaryItems.isEmpty else { return true }
        return await publish(
            ordinaryItems,
            forRunId: run.id,
            in: journal,
            executionFenceToken: executionFenceToken
        ) != nil
    }

    private func settle(
        _ publication: DeviceLegRun.PendingPresentationPublication,
        for run: DeviceLegRun,
        leg: DeviceLeg,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchDisposition {
        let expectedStepId = run.stepId
        let screenId = publication.source.screenId
        var stagedRun = run
        var context = publication.context
        guard let ordinaryItems = DeviceLegPresentationEventProjector
            .routedItems(
                publication.items,
                distinctId: journal.distinctId
            ) else { return .rejected }

        var publishedOrdinaryEvents = false
        var routedEvent: NuxieEvent?
        var routeStepId: String?
        if !ordinaryItems.isEmpty {
            guard let published = await publish(
                ordinaryItems,
                forRunId: run.id,
                in: journal,
                executionFenceToken: executionFenceToken
            ) else { return .rejected }
            publishedOrdinaryEvents = true
            guard published.remainsAuthorized else { return .accepted }
            for item in ordinaryItems {
                guard let capture = published.captures[item.request.eventId],
                      capture.routesLocally,
                      let candidate = DeviceLegPresentationEventProjector.route(
                        in: leg,
                        eventName: capture.event.name,
                        screenId: screenId
                      ) else {
                    continue
                }
                routedEvent = capture.event
                routeStepId = candidate
                break
            }
        }

        do {
            guard let current = try await journal.runs().first(where: {
                $0.id == run.id
                    && $0.completion == nil
                    && $0.stepId == expectedStepId
                    && $0.pendingPresentationPublication?.invocationId
                        == publication.invocationId
            }) else {
                return .publicationFailed(.init(
                    publishedOrdinaryEvents: publishedOrdinaryEvents,
                    run: stagedRun,
                    context: context
                ))
            }
            stagedRun = current
        } catch {
            return .publicationFailed(.init(
                publishedOrdinaryEvents: publishedOrdinaryEvents,
                run: stagedRun,
                context: context
            ))
        }

        if let routedEvent, let routeStepId {
            guard let controlEvent = DeviceLegPresentationEventProjector
                .controlEvent(routedEvent) else {
                return .publicationFailed(.init(
                    publishedOrdinaryEvents: publishedOrdinaryEvents,
                    run: stagedRun,
                    context: context
                ))
            }
            context = ArmedDeviceLeg.Context(
                event: controlEvent.properties,
                responses: publication.context.responses
            )
            do {
                guard let admission = commitAdmission(
                    in: journal,
                    executionFenceToken: executionFenceToken
                ), try await journal.transition(
                    run.id,
                    stepId: routeStepId,
                    context: context,
                    clearingPresentationPublication: publication.invocationId,
                    admission: admission
                ) else {
                    return .publicationFailed(.init(
                        publishedOrdinaryEvents: publishedOrdinaryEvents,
                        run: stagedRun,
                        context: context
                    ))
                }
            } catch {
                LogWarning(
                    "DeviceLegPresentationPublicationCoordinator: failed to persist screen route: \(error)"
                )
                return .publicationFailed(.init(
                    publishedOrdinaryEvents: publishedOrdinaryEvents,
                    run: stagedRun,
                    context: context
                ))
            }
            stagedRun.stepId = routeStepId
            stagedRun.context = context
            stagedRun.park = nil
            stagedRun.pendingPresentationPublication = nil
            return .continueExecution(.init(
                run: stagedRun,
                signal: .init(
                    event: controlEvent,
                    responsesChanged: publication.responsesChanged
                ),
                checkpoint: nil
            ))
        }

        let retainsResponseSignal = publication.responsesChanged
            && Self.stepAcceptsResponseChange(stagedRun.stepId, in: leg)
        do {
            guard let admission = commitAdmission(
                in: journal,
                executionFenceToken: executionFenceToken
            ), try await journal.clearPresentationPublication(
                run.id,
                invocationId: publication.invocationId,
                retainingResponsesChanged: retainsResponseSignal,
                admission: admission
            ) else {
                return .publicationFailed(.init(
                    publishedOrdinaryEvents: publishedOrdinaryEvents,
                    run: stagedRun,
                    context: context
                ))
            }
        } catch {
            LogWarning(
                "DeviceLegPresentationPublicationCoordinator: failed to clear renderer publication: \(error)"
            )
            return .publicationFailed(.init(
                publishedOrdinaryEvents: publishedOrdinaryEvents,
                run: stagedRun,
                context: context
            ))
        }
        stagedRun.pendingPresentationPublication = nil
        guard retainsResponseSignal else { return .accepted }
        stagedRun.park?.pendingResponsesChanged = true
        return .continueExecution(.init(
            run: stagedRun,
            signal: .init(responsesChanged: true),
            checkpoint: Self.controlCheckpoint(from: stagedRun.park)
        ))
    }

    func publish(
        _ items: [RoutedStableSystemEventBatchItem],
        forRunId runId: String,
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchPublication? {
        await publish(
            items,
            forRunId: runId,
            in: journal,
            identityFenceToken: nil,
            executionFenceToken: executionFenceToken
        )
    }

    private func publish(
        _ items: [RoutedStableSystemEventBatchItem],
        forRunId runId: String,
        in journal: DeviceLegRunJournal,
        identityFenceToken suppliedIdentityFenceToken: IdentityFenceToken?,
        executionFenceToken: DeviceLegProfileFenceToken
    ) async -> BatchPublication? {
        let identityFenceToken: IdentityFenceToken
        if let suppliedIdentityFenceToken {
            guard executionFence.isCurrent(executionFenceToken),
                  await isCurrentIdentity(
                    suppliedIdentityFenceToken,
                    journal: journal
                  ) else { return nil }
            identityFenceToken = suppliedIdentityFenceToken
        } else {
            guard let identityFence = identity.performWithCurrentIdentityFence(
                journal.distinctId,
                { _ in () }
            ) else { return nil }
            identityFenceToken = identityFence.token
        }
        let admission = DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFenceToken,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
        for item in items {
            directlyRoutedRunByEventId[item.request.eventId] = runId
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
            guard let capture = captures[item.request.eventId],
                  capture.routesLocally,
                  capture.localRoutePending else {
                removeDirectRoute(
                    eventId: item.request.eventId,
                    runId: runId
                )
                continue
            }
        }
        if await events.drainCommittedRouting() {
            removeDirectRoutes(items, runId: runId)
        }
        guard items.allSatisfy({ captures[$0.request.eventId] != nil }) else {
            return nil
        }
        let executionRemainsAuthorized = executionFence.isCurrent(
            executionFenceToken
        )
        let identityRemainsAuthorized = await isCurrentIdentity(
            identityFenceToken,
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
        let item = RoutedStableSystemEventBatchItem(
            request: StableSystemEventCaptureRequest(
                name: name,
                properties: properties.value,
                eventId: eventId,
                distinctId: journal.distinctId
            ),
            occurredAt: occurredAt
        )
        guard let publication = await publish(
            [item],
            forRunId: runId,
            in: journal,
            identityFenceToken: identityFenceToken,
            executionFenceToken: executionFenceToken
        ), publication.remainsAuthorized else { return nil }
        return publication.captures[eventId]
    }

    private func removeDirectRoutes(
        _ items: [RoutedStableSystemEventBatchItem],
        runId: String
    ) {
        for item in items {
            removeDirectRoute(
                eventId: item.request.eventId,
                runId: runId
            )
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

    private func commitAdmission(
        in journal: DeviceLegRunJournal,
        executionFenceToken: DeviceLegProfileFenceToken
    ) -> DeviceLegCommitAdmission? {
        guard executionFence.isCurrent(executionFenceToken),
              let identityFence = identity.performWithCurrentIdentityFence(
                journal.distinctId,
                { _ in () }
              ) else { return nil }
        return DeviceLegCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
    }

    private static func stepAcceptsResponseChange(
        _ stepId: String,
        in leg: DeviceLeg
    ) -> Bool {
        guard let action = leg.steps.first(where: { $0.id == stepId })?.action,
              DeviceLegActionType(action: action) == .waitUntil,
              case .object(let trigger)? = action["trigger"],
              case .string(let kind)? = trigger["kind"] else {
            return false
        }
        return kind == "response_change"
            || kind == "event_or_response_change"
    }

    private static func controlCheckpoint(
        from park: DeviceLegRun.Park?
    ) -> DeviceLegControlExecutor.Checkpoint? {
        guard let wakeAt = park?.wakeAt,
              let wakeMillis = DeviceLegTime.milliseconds(wakeAt) else {
            return nil
        }
        let anchor = park?.anchorAt.flatMap(DeviceLegTime.milliseconds)
            ?? wakeMillis
        return .init(anchorAtMillis: anchor, wakeAtMillis: wakeMillis)
    }
}

private struct DeviceLegPresentationEventAttribution {
    let journeyId: String
    let experienceId: String
    let experienceVersionId: String
    let legId: String
    let legGeneration: Int

    init(run: DeviceLegRun) {
        journeyId = run.journeyId
        experienceId = run.reference.experienceId
        experienceVersionId = run.reference.versionId
        legId = run.reference.legId
        legGeneration = run.generation
    }

    func adding(to properties: [String: Any]) -> [String: Any] {
        var attributed = properties
        attributed["journey_id"] = journeyId
        attributed["experience_id"] = experienceId
        attributed["experience_version"] = experienceVersionId
        attributed["leg_id"] = legId
        attributed["leg_generation"] = legGeneration
        return attributed
    }

    func adding(
        to values: ExactJSONObject<ExperienceReleaseJSONValue>
    ) -> ExactJSONObject<ExperienceReleaseJSONValue> {
        var attributed = values
        attributed["journey_id"] = .string(journeyId)
        attributed["experience_id"] = .string(experienceId)
        attributed["experience_version"] = .string(experienceVersionId)
        attributed["leg_id"] = .string(legId)
        attributed["leg_generation"] = .number(Double(legGeneration))
        return attributed
    }
}

enum DeviceLegPresentationEventProjector {
    static func attributedProperties(
        _ properties: [String: Any],
        run: DeviceLegRun
    ) -> [String: Any] {
        DeviceLegPresentationEventAttribution(run: run).adding(to: properties)
    }

    static func attributedValues(
        _ values: ExactJSONObject<ExperienceReleaseJSONValue>,
        run: DeviceLegRun
    ) -> ExactJSONObject<ExperienceReleaseJSONValue> {
        DeviceLegPresentationEventAttribution(run: run).adding(to: values)
    }

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
        var properties = attributedValues(payload, run: run)
        properties["screen_id"] = .string(screenId)
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
                request: .init(
                    name: item.name,
                    properties: properties,
                    eventId: item.eventId,
                    distinctId: distinctId
                ),
                occurredAt: item.occurredAt
            ))
        }
        return routed
    }

    static func route(
        in leg: DeviceLeg,
        eventName: String,
        screenId: String?
    ) -> String? {
        screenId.flatMap { screenId in
            leg.routes.first(where: {
                $0.eventName == eventName
                    && $0.host.kind == .screen
                    && $0.host.screenId == screenId
            })?.entryStepId
        } ?? leg.routes.first(where: {
            $0.eventName == eventName && $0.host.kind == .journey
        })?.entryStepId
    }

    static func controlEvent(
        _ event: NuxieEvent
    ) -> DeviceLegControlExecutor.Event? {
        guard let occurredAt = DeviceLegTime.milliseconds(event.timestamp) else {
            return nil
        }
        var properties = ExactJSONObject<ExperienceReleaseJSONValue>()
        for (key, value) in event.properties {
            guard let converted = jsonValue(value) else { continue }
            properties[key] = converted
        }
        return .init(
            name: event.name,
            occurredAtMillis: occurredAt,
            properties: properties
        )
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

    private static func jsonValue(_ value: Any) -> ExperienceReleaseJSONValue? {
        if value is NSNull { return .null }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            guard number.doubleValue.isFinite else { return nil }
            return .number(number.doubleValue)
        }
        if let value = value as? String { return .string(value) }
        if let values = value as? [Any] {
            var result: [ExperienceReleaseJSONValue] = []
            result.reserveCapacity(values.count)
            for value in values {
                guard let converted = jsonValue(value) else { return nil }
                result.append(converted)
            }
            return .array(result)
        }
        if let values = value as? [String: Any] {
            var result = ExactJSONObject<ExperienceReleaseJSONValue>()
            for (key, value) in values {
                guard let converted = jsonValue(value) else { return nil }
                result[key] = converted
            }
            return .object(result)
        }
        return nil
    }

}
