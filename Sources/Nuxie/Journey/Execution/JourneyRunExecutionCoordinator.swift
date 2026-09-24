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
    private let journal: JourneyRunJournal
    private var checkpoint: JourneyControlExecutor.Checkpoint?
    private var signal: JourneyControlExecutor.Signal

    init(
        run: JourneyRun,
        assignments: ExactJSONObject<JourneyFactTable.Assignment?>,
        release: AuthenticatedJourneyRelease,
        signal: JourneyControlExecutor.Signal,
        checkpoint: JourneyControlExecutor.Checkpoint?,
        journal: JourneyRunJournal,
        timezones: SignedTimezoneBundle,
        currentDeviceTimezone: TimeZone
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
        self.signal = signal
        self.checkpoint = checkpoint
        self.journal = journal
    }

    func command(at now: Date) -> Command {
        guard let step = steps[run.stepId],
              let nowMillis = JourneyTime.milliseconds(now) else {
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

    mutating func commit(_ command: AdvanceCommand) async throws {
        _ = try await journal.transition(
            run.id,
            stepId: command.stepId,
            context: command.context,
            experimentExposure: command.experimentExposure
        )
        run.stepId = command.stepId
        run.context = command.context
        if let exposure = command.experimentExposure {
            run.experimentExposures.append(exposure)
        }
        run.park = nil
        checkpoint = nil
    }

    func commit(_ command: ParkCommand) async throws {
        _ = try await journal.transition(
            run.id,
            stepId: command.stepId,
            context: run.context,
            checkpoint: command.checkpoint
        )
    }

    func claimEffect(for command: DispatchCommand) async throws -> String {
        try await journal.claimEffect(
            run.id,
            stepId: command.step.id
        )
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
        _ = try await journal.transition(
            run.id,
            stepId: stepId,
            context: context
        )
        run.stepId = stepId
        run.context = context
        run.park = nil
        checkpoint = nil
        if let presentationSignal {
            signal = presentationSignal
        }
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
        case .override:
            kind = .override
        case .fixed:
            kind = .fixed
        case .fallback:
            kind = .fallback
        }
        return .init(
            experimentId: selection.experimentId,
            stepId: run.stepId,
            variantId: selection.variantId,
            isHoldout: selection.isHoldout,
            kind: kind,
            eventId: UUID.v7().uuidString.lowercased(),
            selectedAt: selectedAt,
            queued: false
        )
    }

}
