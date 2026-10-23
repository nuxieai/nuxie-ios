import Foundation

/// Serializes renderer-authored event publication with the owning identity and
/// execution fences. Direct-route markers prevent EventLog subscribers from
/// racing the renderer callback that owns the same run transition.
actor JourneyPresentationPublicationCoordinator {
    struct BatchPublication: Sendable {
        let captures: [String: DurableTriggerCapture]
        let remainsAuthorized: Bool
        let admission: JourneyCommitAdmission
    }

    struct BatchContinuation: Sendable {
        let run: JourneyRun
        let signal: JourneyControlExecutor.Signal
        let checkpoint: JourneyControlExecutor.Checkpoint?
        var eventID: String? = nil
    }

    enum BatchDisposition: Sendable {
        case rejected
        case accepted
        case continueExecution(BatchContinuation)
    }

    private let identity: IdentityServiceProtocol
    private let events: any RoutedStableSystemEventCapturing
    private let executionFence: JourneyProfileFence
    private var directlyRoutedRunByEventId: [String: String] = [:]
    private struct PreparedBatch {
        let key: CustomerJourneyKey
        let batch: ScreenEmissionBatch
        let revision: Int64
        let records: [StableEventCaptureRecord]
    }
    // The single presentation owner retains its privacy projection across a
    // failed SQL commit. This is discarded at process break, never replayed.
    private var preparedBatch: PreparedBatch?

    init(
        identity: IdentityServiceProtocol,
        events: any RoutedStableSystemEventCapturing,
        executionFence: JourneyProfileFence
    ) {
        self.identity = identity
        self.events = events
        self.executionFence = executionFence
    }

    func directRoute(eventId: String) -> String? {
        directlyRoutedRunByEventId[eventId]
    }

    func consumeDirectRoute(eventId: String) -> String? {
        directlyRoutedRunByEventId.removeValue(forKey: eventId)
    }

    func clearDirectRoutes() {
        directlyRoutedRunByEventId.removeAll()
        preparedBatch = nil
    }

    /// A renderer invocation publishes its privacy projection and selected cursor together.
    func process(_ batch: ScreenEmissionBatch, for run: JourneyRun, leg: Journey,
                 in journal: CustomerJourneyStore, executionFenceToken: JourneyProfileFenceToken,
                 responsesChanged: Bool = false, responseAdvance: JourneyRunExecutionCoordinator.AdvanceCommand? = nil,
                 occurredAt: Date? = nil) async -> BatchDisposition {
        guard let admission = commitAdmission(in: journal, executionFenceToken: executionFenceToken) else { return .rejected }
        var items: [RoutedStableSystemEventBatchItem] = []
        for emission in batch.emissions where !emission.name.hasPrefix("$") {
            guard let date = JourneyPresentationEventProjector.date(emission.occurredAt),
                  let properties = JourneyPresentationEventProjector.properties(payload: ExactJSONObject(emission.payload.mapValues(\.releaseJSONValue)), screenId: batch.source.screenId, run: run) else { return .rejected }
            items.append(.init(request: .init(name: emission.name, properties: properties, eventId: emission.id, distinctId: journal.distinctId,
                journeyOrigin: .init(journeyId: run.journeyId, experienceId: run.reference.experienceId, versionId: run.reference.versionId,
                    legId: run.reference.legId, generation: run.generation, screenId: batch.source.screenId,
                    actionId: batch.source.actionId, invocationId: batch.invocationId, occurrenceId: emission.id)), occurredAt: date))
        }
        do {
            let prepared: PreparedBatch
            if let previous = preparedBatch, previous.key == journal.key(run), previous.batch == batch {
                prepared = previous
            } else {
                prepared = .init(key: journal.key(run), batch: batch, revision: run.cursorRevision,
                    records: try await events.prepareCustomerEvents(items))
                preparedBatch = prepared
            }
            let records = prepared.records
            let routed = records.compactMap(\.event).first { JourneyPresentationEventProjector.route(in: leg, eventName: $0.name, screenId: batch.source.screenId) != nil }
            let routeStep = routed.flatMap { JourneyPresentationEventProjector.route(in: leg, eventName: $0.name, screenId: batch.source.screenId) }
            let step = routeStep ?? responseAdvance?.stepId
            let control = routed.flatMap { JourneyPresentationEventProjector.controlEvent($0.customerEvent) }
            let context = ArmedJourney.Context(event: control?.properties ?? responseAdvance?.context.event ?? run.context.event, responses: run.context.responses)
            var transition = CustomerInputTransition(key: journal.key(run), expectedRevision: prepared.revision, eventId: routed?.id,
                targetKey: "renderer:" + batch.invocationId, stepId: step ?? run.stepId, context: context,
                checkpoint: step == nil ? Self.controlCheckpoint(from: run.park) : nil, nativeSnapshot: run.nativeSnapshot,
                presentationSource: batch.source, rendererInvocationId: batch.invocationId)
            transition.commerceToRetain = run.pendingCommerce
            transition.responsesChanged = responsesChanged
            transition.consumesWait = routeStep == nil && responseAdvance != nil
            transition.rendererOccurredAt = occurredAt.flatMap(JourneyTime.milliseconds)
            for record in records { directlyRoutedRunByEventId[record.eventId] = run.id }
            let result: CustomerExecutionResult
            do { result = try await journal.commit(.applyInput(transition), records: records, admission: admission) }
            catch { removeDirectRoutes(items, runId: run.id); throw error }
            if preparedBatch?.batch == batch { preparedBatch = nil }
            for (record, commit) in zip(records, result.commits) {
                if !commit.localRoutePending { removeDirectRoute(eventId: record.eventId, runId: run.id) }
            }
            guard !result.replayed, let committed = result.journey else { return .accepted }
            guard step != nil else { return .accepted }
            return .continueExecution(.init(run: committed, signal: .init(event: control, responsesChanged: responsesChanged), checkpoint: nil, eventID: routed?.id))
        } catch CustomerStoreError.staleRevision {
            preparedBatch = nil
            return .accepted
        } catch {
            LogWarning("JourneyPresentationPublicationCoordinator: renderer transaction failed: \(error)")
            return .rejected
        }
    }

    func publish(
        _ items: [RoutedStableSystemEventBatchItem],
        forRunId runId: String,
        in journal: CustomerJourneyStore,
        executionFenceToken: JourneyProfileFenceToken
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
        in journal: CustomerJourneyStore,
        identityFenceToken suppliedIdentityFenceToken: IdentityFenceToken?,
        executionFenceToken: JourneyProfileFenceToken
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
        let admission = JourneyCommitAdmission(
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
        in journal: CustomerJourneyStore,
        identityFenceToken: IdentityFenceToken,
        executionFenceToken: JourneyProfileFenceToken
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
        journal: CustomerJourneyStore
    ) async -> Bool {
        guard identity.getDistinctId() == journal.distinctId else {
            return false
        }
        return await MainActor.run {
            identity.publishIfCurrentIdentityFenceToken(token) {}
        }
    }

    private func commitAdmission(
        in journal: CustomerJourneyStore,
        executionFenceToken: JourneyProfileFenceToken
    ) -> JourneyCommitAdmission? {
        guard executionFence.isCurrent(executionFenceToken),
              let identityFence = identity.performWithCurrentIdentityFence(
                journal.distinctId,
                { _ in () }
              ) else { return nil }
        return JourneyCommitAdmission(
            identity: identity,
            identityFenceToken: identityFence.token,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
    }

    private static func controlCheckpoint(
        from park: JourneyRun.Park?
    ) -> JourneyControlExecutor.Checkpoint? {
        guard let wakeAt = park?.wakeAt,
              let wakeMillis = JourneyTime.milliseconds(wakeAt) else {
            return nil
        }
        let anchor = park?.anchorAt.flatMap(JourneyTime.milliseconds)
            ?? wakeMillis
        return .init(anchorAtMillis: anchor, wakeAtMillis: wakeMillis)
    }
}

private struct JourneyPresentationEventAttribution {
    let journeyId: String
    let experienceId: String
    let experienceVersionId: String
    let legId: String
    let legGeneration: Int

    init(run: JourneyRun) {
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
        attributed["experience_version_id"] = experienceVersionId
        attributed["leg_id"] = legId
        attributed["leg_generation"] = legGeneration
        return attributed
    }

    func adding(
        to values: ExactJSONObject<JourneyReleaseJSONValue>
    ) -> ExactJSONObject<JourneyReleaseJSONValue> {
        var attributed = values
        attributed["journey_id"] = .string(journeyId)
        attributed["experience_id"] = .string(experienceId)
        attributed["experience_version_id"] = .string(experienceVersionId)
        attributed["leg_id"] = .string(legId)
        attributed["leg_generation"] = .number(Double(legGeneration))
        return attributed
    }
}

enum JourneyPresentationEventProjector {
    static func attributedProperties(
        _ properties: [String: Any],
        run: JourneyRun
    ) -> [String: Any] {
        JourneyPresentationEventAttribution(run: run).adding(to: properties)
    }

    static func attributedValues(
        _ values: ExactJSONObject<JourneyReleaseJSONValue>,
        run: JourneyRun
    ) -> ExactJSONObject<JourneyReleaseJSONValue> {
        JourneyPresentationEventAttribution(run: run).adding(to: values)
    }

    static func properties(
        payload: ExactJSONObject<JourneyReleaseJSONValue>,
        screenId: String,
        run: JourneyRun
    ) -> [String: Any]? {
        foundationValues(values(
            payload: payload,
            screenId: screenId,
            run: run
        ))
    }

    static func values(
        payload: ExactJSONObject<JourneyReleaseJSONValue>,
        screenId: String,
        run: JourneyRun
    ) -> ExactJSONObject<JourneyReleaseJSONValue> {
        var properties = attributedValues(payload, run: run)
        properties["screen_id"] = .string(screenId)
        return properties
    }

    static func route(
        in leg: Journey,
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
    ) -> JourneyControlExecutor.Event? {
        guard let occurredAt = JourneyTime.milliseconds(event.timestamp) else {
            return nil
        }
        var properties = ExactJSONObject<JourneyReleaseJSONValue>()
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
        _ properties: ExactJSONObject<JourneyReleaseJSONValue>
    ) -> [String: Any]? {
        guard let data = try? ExactJSONCodec.encode(properties) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jsonValue(_ value: Any) -> JourneyReleaseJSONValue? {
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
            var result: [JourneyReleaseJSONValue] = []
            result.reserveCapacity(values.count)
            for value in values {
                guard let converted = jsonValue(value) else { return nil }
                result.append(converted)
            }
            return .array(result)
        }
        if let values = value as? [String: Any] {
            var result = ExactJSONObject<JourneyReleaseJSONValue>()
            for (key, value) in values {
                guard let converted = jsonValue(value) else { return nil }
                result[key] = converted
            }
            return .object(result)
        }
        return nil
    }

}
