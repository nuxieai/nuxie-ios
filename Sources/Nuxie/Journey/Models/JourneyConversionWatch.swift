import Foundation

/// Small measurement state. It never owns a release pin, scene, or execution cursor.
struct JourneyConversionWatch: Codable, Sendable {
    typealias Occurrence = ArmedJourney.Conversion.Occurrence
    struct Goal: Codable, Sendable {
        struct Criterion: Codable, Sendable {
            enum Kind: String, Codable, Sendable { case event, segmentEnter = "segment_enter", segmentLeave = "segment_leave" }
            let type: Kind
            let eventName: String?
            let segmentId: String?
            let condition: [String: JourneyReleaseJSONValue]?
        }
        struct Attribution: Codable, Sendable {
            enum Basis: String, Codable, Sendable { case entry, firstShown = "first_shown" }
            let basis: Basis
            let window: Journey.Duration
        }
        let criterion: Criterion
        let attribution: Attribution
        var windowMillis: Int? {
            guard let seconds = attribution.window.seconds, seconds > 0, seconds <= 90 * 86_400 else { return nil }
            return seconds * 1000
        }
    }

    static let backdateMillis = 30 * 86_400_000
    let journeyId: String
    let experienceId: String
    let versionId: String
    let policyHash: String
    let goal: Goal
    let startedAt: Int
    var basis: Occurrence?
    var conversion: Occurrence?
    var serverRevision: Int?
    var legCompletedAt: Int?

    init(run: JourneyRun, policy: Journey.Policy, delivery: ArmedJourney.Conversion?) throws {
        guard let raw = policy.goal else { throw JourneyJournalError.invalidState }
        goal = try ExactJSONCodec.decode(Goal.self, from: ExactJSONCodec.encode(raw))
        guard goal.windowMillis != nil else { throw JourneyJournalError.invalidState }
        if !run.isEnrollment && delivery == nil { throw JourneyJournalError.invalidState }
        journeyId = run.journeyId
        experienceId = run.reference.experienceId
        versionId = run.reference.versionId
        policyHash = SHA256Provider.hexDigest(try ExactJSONCodec.encode(policy))
        startedAt = delivery?.startedAt ?? Self.millis(run.startedAt)
        if goal.attribution.basis == .entry {
            basis = .init(eventId: journeyId, occurredAt: startedAt)
        }
        if let delivery { try reconcile(delivery) }
    }

    mutating func reconcile(_ delivery: ArmedJourney.Conversion) throws {
        guard delivery.startedAt == startedAt, let window = goal.windowMillis else { throw JourneyJournalError.invalidState }
        if let serverRevision, delivery.revision <= serverRevision { return }
        if let basis = delivery.basis {
            guard basis.occurredAt >= startedAt else { throw JourneyJournalError.invalidState }
            if goal.attribution.basis == .entry && (basis.occurredAt != startedAt || basis.eventId != journeyId) {
                throw JourneyJournalError.invalidState
            }
        } else if goal.attribution.basis == .entry { throw JourneyJournalError.invalidState }
        if let converted = delivery.conversion {
            guard let basis = delivery.basis, converted.occurredAt >= basis.occurredAt,
                  converted.occurredAt <= basis.occurredAt + window else { throw JourneyJournalError.invalidState }
        }
        basis = delivery.basis
        conversion = delivery.conversion
        serverRevision = delivery.revision
    }

    func matches(_ event: NuxieEvent) async -> Bool {
        // Purchase telemetry routes locally; verified commercial measurement
        // arrives through the server conversion projection.
        guard event.name != "$purchase_completed", event.name != "$purchase_synced" else { return false }
        switch goal.criterion.type {
        case .event:
            guard event.name == goal.criterion.eventName else { return false }
        case .segmentEnter:
            return event.name == "$segment_entered" && event.properties["segment_id"] as? String == goal.criterion.segmentId
        case .segmentLeave:
            return event.name == "$segment_exited" && event.properties["segment_id"] as? String == goal.criterion.segmentId
        }
        guard let condition = goal.criterion.condition else { return true }
        do {
            let ir = try ExactJSONCodec.decode(IREnvelope.self, from: ExactJSONCodec.encode(condition))
            guard ir.ir_version == 1, ir.isSupportedByThisEngine else { return false }
            return try await IRInterpreter(ctx: EvalContext(now: event.timestamp, event: event, journeyId: journeyId)).evalBool(ir.expr)
        } catch { return false }
    }

    func shouldRetain(at now: Int, executing: Bool) -> Bool {
        if executing { return true }
        let expires = basis.map { $0.occurredAt + (goal.windowMillis ?? 0) }
            ?? legCompletedAt ?? (startedAt + 90 * 86_400_000)
        return now <= expires + Self.backdateMillis
    }

    // Date stores seconds relative to 2001. Converting an integral wire
    // millisecond through that epoch can land just below the integer; truncation
    // would pull an out-of-window occurrence back inside the inclusive boundary.
    static func millis(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    static func normalized(_ event: NuxieEvent, acceptedAt: Date) -> NuxieEvent? {
        let raw = (event.timestamp.timeIntervalSince1970 * 1000).rounded()
        let received = (acceptedAt.timeIntervalSince1970 * 1000).rounded()
        guard raw.isFinite, received.isFinite, raw >= 0, received >= 0,
              raw <= 9_007_199_254_740_991, received <= 9_007_199_254_740_991,
              raw >= received - Double(backdateMillis) else { return nil }
        return NuxieEvent(id: event.id, name: event.name, forwardingName: event.forwardingName, distinctId: event.distinctId,
            properties: event.properties, timestamp: Date(timeIntervalSince1970: Double(Int(min(raw, received))) / 1000), journeyOrigin: event.journeyOrigin)
    }

    /// Apply only a committed occurrence. The server reconciles canonical
    /// cross-device credit; local measurement never retracts visible work.
    static func apply(
        event: NuxieEvent, acceptedAt: Date, matching: Set<String>,
        watches: inout [String: Self]
    ) {
        guard event.name != "$purchase_completed", event.name != "$purchase_synced" else { return }
        guard let event = normalized(event, acceptedAt: acceptedAt) else { return }
        let time = millis(event.timestamp)
        let reportedJourney = event.properties["journey_id"] as? String
        let hasContext = ["journey_id", "experience_id", "experience_version_id"].contains { event.properties[$0] != nil }
        if hasContext {
            guard let reportedJourney, let watch = watches[reportedJourney],
                  event.properties["experience_id"] as? String == watch.experienceId,
                  event.properties["experience_version_id"] as? String == watch.versionId else { return }
        }
        if event.name == JourneyEvents.experienceShown, let reportedJourney, var watch = watches[reportedJourney],
           watch.goal.attribution.basis == .firstShown, time >= watch.startedAt,
           watch.basis == nil {
            watch.basis = .init(eventId: event.id, occurredAt: time)
            watches[reportedJourney] = watch
        }
        let direct = event.journeyOrigin?.journeyId
        if let origin = event.journeyOrigin {
            guard origin.occurrenceId == event.id, let watch = watches[origin.journeyId],
                  origin.experienceId == watch.experienceId, origin.versionId == watch.versionId else { return }
            if hasContext, reportedJourney != origin.journeyId { return }
        } else if hasContext { return }
        let eligible = watches.values.filter { watch in
            guard matching.contains(watch.journeyId), let basis = watch.basis,
                  let window = watch.goal.windowMillis,
                  time >= basis.occurredAt, time <= basis.occurredAt + window else { return false }
            if time == basis.occurredAt && !basis.eventId.utf16.lexicographicallyPrecedes(event.id.utf16) { return false }
            return direct == nil || watch.journeyId == direct
        }.sorted { left, right in
            if left.basis!.occurredAt != right.basis!.occurredAt { return left.basis!.occurredAt > right.basis!.occurredAt }
            return left.journeyId.utf16.lexicographicallyPrecedes(right.journeyId.utf16)
        }
        guard var selected = eligible.first, selected.conversion == nil else { return }
        selected.conversion = .init(eventId: event.id, occurredAt: time)
        watches[selected.journeyId] = selected
    }
}
