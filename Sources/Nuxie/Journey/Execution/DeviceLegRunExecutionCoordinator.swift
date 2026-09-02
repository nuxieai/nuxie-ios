import Foundation

/// Owns the deterministic control loop state and its durable cursor changes.
/// Host effects and presentation lifecycle stay with `DeviceLegService`, which
/// executes the commands returned here and feeds their outcomes back in.
struct DeviceLegRunExecutionCoordinator {
    static let iterationLimit = 10_000

    struct AdvanceCommand {
        let stepId: String
        let context: ArmedDeviceLeg.Context
        let experimentExposure: DeviceLegRun.ExperimentExposure?
    }

    struct ParkCommand {
        let stepId: String
        let checkpoint: DeviceLegControlExecutor.Checkpoint
    }

    struct DispatchCommand {
        let step: DeviceLeg.Step
        let action: [String: ExperienceReleaseJSONValue]
    }

    enum Command {
        case advance(AdvanceCommand)
        case park(ParkCommand)
        case complete(outcome: String)
        case dispatch(DispatchCommand)
        case invalid
    }

    private(set) var run: DeviceLegRun

    private let assignments: ExactJSONObject<DeviceLegFactTable.Assignment?>
    private let steps: [String: DeviceLeg.Step]
    private let executor: DeviceLegControlExecutor
    private let journal: DeviceLegRunJournal
    private var checkpoint: DeviceLegControlExecutor.Checkpoint?
    private var signal: DeviceLegControlExecutor.Signal

    init(
        run: DeviceLegRun,
        assignments: ExactJSONObject<DeviceLegFactTable.Assignment?>,
        release: AuthenticatedDeviceLegRelease,
        signal: DeviceLegControlExecutor.Signal,
        checkpoint: DeviceLegControlExecutor.Checkpoint?,
        journal: DeviceLegRunJournal,
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
        executor = DeviceLegControlExecutor(
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
              let nowMillis = Self.milliseconds(now) else {
            return .invalid
        }
        switch executor.evaluate(
            step: step,
            context: run.context,
            assignments: assignments,
            nowMillis: nowMillis,
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
        presentationSignal: DeviceLegControlExecutor.Signal?
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
        for selection: DeviceLegControlExecutor.ExperimentSelection?,
        selectedAt: Date
    ) -> DeviceLegRun.ExperimentExposure? {
        guard let selection,
              !run.experimentExposures.contains(where: {
                  $0.experimentId == selection.experimentId
              }) else { return nil }
        let kind: DeviceLegRun.ExperimentExposure.Kind
        let assignedVariantId: String?
        switch selection.source {
        case .profile:
            kind = .assigned
            assignedVariantId = selection.variantId
        case .noAssignment:
            kind = .fallback
            assignedVariantId = nil
        case .invalidAssignment(let variantId):
            kind = .invalidAssignment
            assignedVariantId = variantId
        }
        return .init(
            experimentId: selection.experimentId,
            variantId: selection.variantId,
            assignedVariantId: assignedVariantId,
            isHoldout: selection.isHoldout,
            kind: kind,
            eventId: UUID.v7().uuidString.lowercased(),
            selectedAt: selectedAt,
            shownAt: nil,
            queued: false
        )
    }

    private static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded(.towardZero))
    }
}
