import Foundation

/// Owns the deterministic control loop state and its durable cursor changes.
/// Host effects and presentation lifecycle stay with `JourneyService`, which
/// executes the commands returned here and feeds their outcomes back in.
struct JourneyRunExecutionCoordinator {
    static let iterationLimit = 10_000

    struct AdvanceCommand {
        let stepId: String
        let context: ArmedJourney.Context
        let experimentExposure: JourneyRun.ExperimentExposure?
    }

    struct ParkCommand {
        let stepId: String
        let checkpoint: JourneyControlExecutor.Checkpoint
    }

    struct DispatchCommand {
        let step: Journey.Step
        let action: [String: JourneyReleaseJSONValue]
    }

    enum Command {
        case advance(AdvanceCommand)
        case park(ParkCommand)
        case complete(outcome: String)
        case dispatch(DispatchCommand)
        case invalid
    }

    private(set) var run: JourneyRun

    private let assignments: ExactJSONObject<JourneyFactTable.Assignment?>
    private let steps: [String: Journey.Step]
    private let executor: JourneyControlExecutor
    private let journal: CustomerJourneyStore
    private var checkpoint: JourneyControlExecutor.Checkpoint?
    private var signal: JourneyControlExecutor.Signal
    /// An event-started pass runs behind the real clock by how late its event
    /// was handled, taken at its first evaluation, so its waits count from the
    /// event's own time and time spent in the pass still counts. Once it parks,
    /// the saved checkpoint owns the wait and later passes use the real clock.
    /// SQL retains the sampled lag and evaluation time across failed saves.
    private let startingEventAt: Date?
    private(set) var startingLag: TimeInterval?

    init(
        run: JourneyRun,
        assignments: ExactJSONObject<JourneyFactTable.Assignment?>,
        release: AuthenticatedJourneyRelease,
        signal: JourneyControlExecutor.Signal,
        checkpoint: JourneyControlExecutor.Checkpoint?,
        journal: CustomerJourneyStore,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone,
        startingEventAt: Date? = nil,
        startingLag: TimeInterval? = nil
    ) {
        self.run = run
        self.assignments = assignments
        let leg = release.descriptor.leg
        steps = Dictionary(uniqueKeysWithValues: leg.steps.map { ($0.id, $0) })
        let appDefaultTimezone: String? = if case .string(let value)? =
            release.descriptor.metadata["appDefaultTimezone"] { value } else {
                nil
            }
        executor = JourneyControlExecutor(
            timezones: timezones,
            currentDeviceTimezone: currentDeviceTimezone,
            appDefaultTimezone: appDefaultTimezone
        )
        if run.cursorRevision > 0, run.inputEventId != nil, run.lastConsumed?.eventId == run.inputEventId { self.signal = .init() }
        else { self.signal = signal }
        self.checkpoint = checkpoint
        self.journal = journal
        self.startingEventAt = startingEventAt
        self.startingLag = startingLag
    }

    mutating func reload(_ journey: JourneyRun) { run = journey; checkpoint = nil }

    mutating func useNativeValues(
        _ values: ExactJSONObject<JourneyReleaseJSONValue>,
        formAnswers: ExactJSONObject<ExactJSONObject<JourneyReleaseJSONValue>> = [:]
    ) {
        run.context = .init(event: run.context.event, responses: values, formAnswers: formAnswers)
    }

    mutating func command(at now: Date) async throws -> Command {
        // A future event time never extends a wait: the lag is never negative.
        if startingLag == nil, let startingEventAt {
            startingLag = max(0, now.timeIntervalSince(startingEventAt))
        }
        let sampledTrigger = startingLag.map { now.addingTimeInterval(-$0) } ?? startingEventAt
        let evaluationContext = run.context
        run = try await journal.beginEvaluation(run, at: now, triggeringAt: sampledTrigger)
        run.context = evaluationContext
        startingLag = run.initialLagMillis.map { Double($0) / 1000 }
        guard let step = steps[run.stepId], let savedAt = run.evaluationAt else { return .invalid }
        let nowMillis = savedAt - (run.initialLagMillis ?? 0)
        guard nowMillis >= 0 else {
            return .invalid
        }
        switch executor.evaluate(
            step: step,
            context: run.context,
            assignments: assignments,
            nowMillis: nowMillis,
            customer: run.executionSnapshot.customer ?? [:],
            checkpoint: checkpoint,
            signal: signal
        ) {
        case .advance(let stepId, let context, let selection):
            return .advance(.init(
                stepId: stepId,
                context: context,
                experimentExposure: exposure(
                    for: selection,
                    selectedAt: now
                )
            ))
        case .park(let stepId, let checkpoint):
            return .park(.init(stepId: stepId, checkpoint: checkpoint))
        case .complete(let outcome):
            return .complete(outcome: outcome)
        case .dispatch(_, let action):
            return .dispatch(.init(step: step, action: action))
        case .invalid:
            return .invalid
        }
    }

    mutating func commit(_ command: AdvanceCommand, admission: JourneyCommitAdmission? = nil) async throws {
        let consumedWait = steps[run.stepId]?.action.map { JourneyActionType(action: $0) == .waitUntil } ?? false
        guard try await journal.transition(
            run.id,
            stepId: command.stepId,
            context: command.context,
            experimentExposure: command.experimentExposure,
            expectedRevision: run.cursorRevision,
            admission: admission
        ) else { throw JourneyExecutionError.invalidState }
        run = try await journal.current(run.id)
        if consumedWait { signal = .init() }
        run.park = nil
        checkpoint = nil
    }

    func commit(_ command: ParkCommand, snapshot: ExperienceRunSnapshot?, admission: JourneyCommitAdmission) async throws {
        let step = steps[command.stepId]
        let kind: String
        switch step?.action.flatMap({ JourneyActionType(action: $0) }) {
        case .delay: kind = "delay"
        case .timeWindow: kind = "time_window"
        default:
            if let step, try executor.acceptsResponseChange(step), try executor.eventNameForWait(step) == nil { kind = "response" }
            else { kind = "event" }
        }
        guard try await journal.transition(
            run.id,
            stepId: command.stepId,
            context: run.context,
            checkpoint: command.checkpoint,
            nativeSnapshot: snapshot, waitKind: kind,
            expectedRevision: run.cursorRevision,
            admission: admission
        ) else { throw JourneyExecutionError.invalidState }
    }

    mutating func claimEffect(for command: DispatchCommand) async throws -> String {
        try await journal.claimEffect(
            run.id,
            stepId: command.step.id, expectedRevision: run.cursorRevision
        )
    }

    /// Associates every decision reached since the previous presentation
    /// boundary with the next screen before that screen can become visible.
    /// A callback from the screen being replaced therefore cannot expose a
    /// decision that selected the destination screen.
    mutating func bindExperimentExposures(
        to screenId: String,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        guard run.experimentExposures.contains(where: {
            $0.shownAt == nil && $0.presentationScreenId == nil
        }) else { return true }
        guard try await journal.bindExperimentExposures(
            run.id,
            to: screenId,
            admission: admission
        ) else { return false }
        for index in run.experimentExposures.indices
        where run.experimentExposures[index].shownAt == nil
            && run.experimentExposures[index].presentationScreenId == nil {
            run.experimentExposures[index].presentationScreenId = screenId
        }
        return true
    }

    /// Persists the selected action outlet and updates the in-memory cursor.
    /// A false result means the release exposed an outlet that its own control
    /// step does not define.
    mutating func commit(
        outlet: String,
        for command: DispatchCommand,
        presentationSignal: JourneyControlExecutor.Signal?
    ) async throws -> Bool {
        guard case .advance(let stepId, let context, _) = executor.selectOutlet(
            command.step,
            outlet: outlet,
            context: run.context
        ) else { return false }
        let latest = try await journal.current(run.id)
        guard let effectId = latest.effectReceipts[command.step.id],
              let committed = try await journal.settlePresentationCommerce(run.id, stepId: command.step.id, effectId: effectId,
                nextStepId: stepId, eventId: presentationSignal?.eventId, admission: nil) else { return false }
        run = committed
        run = try await journal.current(run.id)
        run.park = nil
        checkpoint = nil
        signal = .init()
        return true
    }

    private func exposure(
        for selection: JourneyControlExecutor.ExperimentSelection?,
        selectedAt: Date
    ) -> JourneyRun.ExperimentExposure? {
        guard let selection,
              !run.experimentExposures.contains(where: {
                  $0.experimentId == selection.experimentId
              }) else { return nil }
        let kind: JourneyRun.ExperimentExposure.Kind
        switch selection.source {
        case .profile:
            kind = .assigned
        case .fallback:
            kind = .fallback
        }
        return .init(
            experimentId: selection.experimentId,
            variantId: selection.variantId,
            isHoldout: selection.isHoldout,
            kind: kind,
            eventId: UUID.v7().uuidString.lowercased(),
            selectedAt: selectedAt,
            presentationScreenId: nil,
            shownAt: nil
        )
    }

}
