import Foundation

/// Evaluates one authenticated flat-leg transition. The caller persists every
/// advance or park before evaluating another step or dispatching an effect.
struct DeviceLegControlExecutor {
    struct Checkpoint: Codable, Equatable, Sendable {
        let anchorAtMillis: Int64
        let wakeAtMillis: Int64
    }

    struct Event: Sendable {
        let name: String
        let occurredAtMillis: Int64
        let properties: ExactJSONObject<ExperienceReleaseJSONValue>
    }

    struct Signal: Sendable {
        let event: Event?
        let responsesChanged: Bool
        init(event: Event? = nil, responsesChanged: Bool = false) {
            self.event = event; self.responsesChanged = responsesChanged
        }
    }

    struct ExperimentSelection: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case profile
            case noAssignment
            case invalidAssignment(variantId: String)
        }

        let experimentId: String
        let variantId: String
        let isHoldout: Bool
        let source: Source
    }

    enum Result {
        case advance(
            stepId: String,
            context: ArmedDeviceLeg.Context,
            experimentSelection: ExperimentSelection?
        )
        case park(stepId: String, checkpoint: Checkpoint)
        case complete(outcome: String)
        case dispatch(stepId: String, action: [String: ExperienceReleaseJSONValue])
        case invalid
    }

    let timezones: SignedTimezoneBundle
    let currentDeviceTimezone: TimeZone
    let appDefaultTimezone: String?

    func evaluate(
        step: DeviceLeg.Step,
        context: ArmedDeviceLeg.Context,
        assignments: ExactJSONObject<DeviceLegFactTable.Assignment?>,
        nowMillis: Int64,
        checkpoint: Checkpoint? = nil,
        signal: Signal = .init()
    ) -> Result {
        do { return try evaluateChecked(step, context: context, assignments: assignments,
                                        nowMillis: nowMillis, checkpoint: checkpoint, signal: signal) }
        catch { return .invalid }
    }

    func selectOutlet(_ step: DeviceLeg.Step, outlet: String, context: ArmedDeviceLeg.Context) -> Result {
        guard step.kind == .action, let outlets = step.outlets else { return .invalid }
        return advance(outlets, outlet: outlet, context: context)
    }

    private func evaluateChecked(
        _ step: DeviceLeg.Step,
        context: ArmedDeviceLeg.Context,
        assignments: ExactJSONObject<DeviceLegFactTable.Assignment?>,
        nowMillis: Int64,
        checkpoint: Checkpoint?,
        signal: Signal
    ) throws -> Result {
        if step.kind == .complete {
            guard let outcome = step.outcome else { return .invalid }
            return .complete(outcome: outcome)
        }
        guard let action = step.action, let outlets = step.outlets,
              case .string(let type)? = action["type"] else { return .invalid }
        switch type {
        case "condition":
            let control = try decode(CompiledCondition.self, action)
            let selected = control.branches.first {
                DeviceLegValues.evaluate($0.condition, context: context) == true
            }?.id ?? "default"
            return advance(outlets, outlet: selected, context: context)
        case "experiment":
            let control = try decode(CompiledExperiment.self, action)
            guard let first = control.variants.first?.id else { return .invalid }
            let assignment: DeviceLegFactTable.Assignment?
            if let stored = assignments[control.experimentId], let stored {
                assignment = stored
            } else {
                assignment = nil
            }
            let assignedVariantId = assignment?.variantId
            let hasAssignedVariant = control.variants.contains {
                $0.id == assignedVariantId
            }
            let selected = hasAssignedVariant ? assignedVariantId! : first
            let source: ExperimentSelection.Source
            if hasAssignedVariant {
                source = .profile
            } else if let assignedVariantId {
                source = .invalidAssignment(variantId: assignedVariantId)
            } else {
                source = .noAssignment
            }
            return advance(
                outlets,
                outlet: selected,
                context: context,
                experimentSelection: .init(
                    experimentId: control.experimentId,
                    variantId: selected,
                    isHoldout: assignment?.isHoldout ?? false,
                    source: source
                )
            )
        case "time_window":
            let control = try decode(CompiledTimeWindow.self, action)
            guard let timezone = TimeWindowMath.resolveTimezone(control.timezone, current: currentDeviceTimezone,
                                                                 appDefault: appDefaultTimezone, bundle: timezones) else { return .invalid }
            switch TimeWindowMath.evaluate(now: date(nowMillis), startTime: control.startTime, endTime: control.endTime,
                                           daysOfWeek: control.daysOfWeek, timezone: timezone) {
            case .inWindow: return advance(outlets, outlet: "inside", context: context)
            case .pause(let until):
                guard let wake = milliseconds(until) else { return .invalid }
                return .park(stepId: step.id, checkpoint: .init(anchorAtMillis: checkpoint?.anchorAtMillis ?? nowMillis,
                                                                wakeAtMillis: wake))
            case .malformed, .unavailable: return .invalid
            }
        case "delay":
            let control = try decode(CompiledDelay.self, action)
            let current: Checkpoint
            if let checkpoint { current = checkpoint }
            else {
                let (wake, overflow) = nowMillis.addingReportingOverflow(Int64(control.durationMs))
                guard !overflow else { return .invalid }
                current = .init(anchorAtMillis: nowMillis, wakeAtMillis: wake)
            }
            return nowMillis < current.wakeAtMillis ? .park(stepId: step.id, checkpoint: current)
                : advance(outlets, outlet: "next", context: context)
        case "wait_until":
            let control = try decode(CompiledWait.self, action)
            let current: Checkpoint
            if let checkpoint { current = checkpoint }
            else {
                let (wake, overflow) = nowMillis.addingReportingOverflow(Int64(control.maxTimeMs))
                guard !overflow else { return .invalid }
                current = .init(anchorAtMillis: nowMillis, wakeAtMillis: wake)
            }
            let eventName: String?
            let acceptsEvent: Bool
            let acceptsResponse: Bool
            switch control.trigger {
            case .responseChange: eventName = nil; acceptsEvent = false; acceptsResponse = true
            case .event(let name, _): eventName = name; acceptsEvent = true; acceptsResponse = false
            case .eventOrResponseChange(let name, _): eventName = name; acceptsEvent = true; acceptsResponse = true
            }
            let eventMatches = acceptsEvent && signal.event?.name == eventName && signal.event.map {
                current.anchorAtMillis...current.wakeAtMillis ~= $0.occurredAtMillis
            } == true
            let responseMatches = acceptsResponse && signal.responsesChanged
            let evaluated = eventMatches ? ArmedDeviceLeg.Context(event: signal.event!.properties, responses: context.responses) : context
            if (eventMatches || responseMatches), DeviceLegValues.evaluate(control.condition, context: evaluated) == true {
                return advance(outlets, outlet: "satisfied", context: evaluated)
            }
            if nowMillis >= current.wakeAtMillis { return advance(outlets, outlet: "timeout", context: context) }
            return .park(stepId: step.id, checkpoint: current)
        default:
            return .dispatch(stepId: step.id, action: action)
        }
    }

    private func advance(
        _ outlets: [String: String],
        outlet: String,
        context: ArmedDeviceLeg.Context,
        experimentSelection: ExperimentSelection? = nil
    ) -> Result {
        outlets[outlet].map {
            .advance(
                stepId: $0,
                context: context,
                experimentSelection: experimentSelection
            )
        } ?? .invalid
    }

    private func decode<T: Decodable>(_ type: T.Type, _ action: [String: ExperienceReleaseJSONValue]) throws -> T {
        try ExactJSONCodec.decode(type, from: ExactJSONCodec.encode(ExperienceReleaseJSONValue.object(.init(action))))
    }

    private func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    private func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
        return Int64(value.rounded(.towardZero))
    }
}

private struct CompiledDelay: Decodable { let durationMs: Int }
private struct CompiledCondition: Decodable {
    struct Branch: Decodable { let id: String; let condition: JourneyCondition }
    let branches: [Branch]
}
private struct CompiledExperiment: Decodable {
    struct Variant: Decodable { let id: String }
    let experimentId: String
    let variants: [Variant]
}
private struct CompiledTimeWindow: Decodable {
    let startTime: String
    let endTime: String
    let timezone: JourneyTimezone
    let daysOfWeek: [Int]
}
private struct CompiledWait: Decodable {
    let trigger: JourneyWaitTrigger
    let condition: JourneyCondition
    let maxTimeMs: Int
}
