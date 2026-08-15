import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(Darwin)
import Darwin
#endif

struct ExperiencePresentationTimestamp: Equatable, Sendable {
    let wallClock: Date
    let monotonicTime: TimeInterval

    static func now(wallClock: Date = Date()) -> Self {
        Self(
            wallClock: wallClock,
            monotonicTime: monotonicNow()
        )
    }

    /// Maps an externally supplied monotonic instant into wall-clock time
    /// using one coherent callback-time observation of both clocks. This
    /// preserves the renderer's physical presentation time while avoiding a
    /// wall clock sampled later by an asynchronously forwarded callback.
    static func anchored(
        monotonicTime: TimeInterval,
        observedAt: Self
    ) -> Self {
        // `MTLDrawable.presentedTime` is allowed to report zero when the
        // system has no presentation timestamp even though its presented
        // handler fired. Zero is not in the CACurrentMediaTime domain and
        // would manufacture a large negative latency, so retain the stronger
        // handler evidence while using its coherent callback observation.
        guard monotonicTime.isFinite, monotonicTime > 0 else {
            return observedAt
        }
        return Self(
            wallClock: observedAt.wallClock.addingTimeInterval(
                monotonicTime - observedAt.monotonicTime
            ),
            monotonicTime: monotonicTime
        )
    }

    static func monotonicNow() -> TimeInterval {
        #if canImport(QuartzCore)
        // Runtime drawable presentation times are reported in this clock domain.
        return CACurrentMediaTime()
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}

/// Immutable correlation carried explicitly from a public trigger call to any
/// presentation it causes. It intentionally is not task-local: a trigger can
/// cross actors, spawn work, and leave behind a resumable journey.
struct ExperiencePresentationAttempt: Equatable, Sendable {
    let id: String
    let triggerEvent: String
    let startedAt: Date
    let startedAtMonotonicTime: TimeInterval?

    init(
        id: String,
        triggerEvent: String,
        startedAt: Date,
        startedAtMonotonicTime: TimeInterval? = nil
    ) {
        self.id = id
        self.triggerEvent = triggerEvent
        self.startedAt = startedAt
        self.startedAtMonotonicTime = startedAtMonotonicTime
    }

    static func make(
        triggerEvent: String,
        startedAt: Date,
        startedAtMonotonicTime: TimeInterval = ExperiencePresentationTimestamp.monotonicNow()
    ) -> Self {
        Self(
            id: UUID.v7().uuidString,
            triggerEvent: triggerEvent,
            startedAt: startedAt,
            startedAtMonotonicTime: startedAtMonotonicTime
        )
    }

    var triggerRoutingSpan: ExperiencePresentationTraceSpan? {
        guard let startedAtMonotonicTime else { return nil }
        return ExperiencePresentationTraceSpan(
            id: "\(id).trigger-routing",
            work: .triggerRouting,
            startedAt: ExperiencePresentationTimestamp(
                wallClock: startedAt,
                monotonicTime: startedAtMonotonicTime
            )
        )
    }
}

enum ExperiencePresentationRoute: String, Equatable, Sendable {
    case direct
    case journey
}

enum ExperiencePresentationWork: String, Equatable, Sendable {
    case triggerRouting = "trigger_routing"
    case experienceResolution = "experience_resolution"
    case artifactAcquisition = "artifact_acquisition"
    case externalAssetPreparation = "external_asset_preparation"
    case descriptorAuthentication = "descriptor_authentication"
    case storeKitProductLookup = "storekit_product_lookup"
    case runtimePreparation = "runtime_preparation"
    case displayPresentation = "display_presentation"
}

struct ExperiencePresentationTraceSpan: Equatable, Sendable {
    let id: String
    let work: ExperiencePresentationWork
    let startedAt: ExperiencePresentationTimestamp
}

enum ExperiencePresentationTraceStage: Equatable, Sendable {
    case triggerAccepted
    case eventTracked(eventId: String)
    case journeyMatched(journeyId: String)
    case presentationRequested(
        experienceVersionId: String,
        route: ExperiencePresentationRoute
    )
    case runtimeReady
    case shellPresented
    case revealed
    case firstPresentedDrawable(
        screenId: String,
        frameNumber: UInt64,
        pixels: UInt64,
        drawCalls: UInt64,
        provenance: ExperienceRuntimePresentedDrawable.Provenance
    )
    case firstAcceptedInput(screenId: String, eventCount: Int)
    case workStarted(
        spanId: String,
        work: ExperiencePresentationWork,
        attributes: [String: String]
    )
    case workCompleted(
        spanId: String,
        work: ExperiencePresentationWork,
        durationMilliseconds: Double,
        attributes: [String: String]
    )
    case workFailed(
        spanId: String,
        work: ExperiencePresentationWork,
        durationMilliseconds: Double,
        errorCode: String,
        attributes: [String: String]
    )
    case presentationFailed(
        route: ExperiencePresentationRoute,
        errorCode: String
    )
    case presentationCleanupCompleted
}

struct ExperiencePresentationTraceEvent: Equatable, Sendable {
    let attempt: ExperiencePresentationAttempt
    let stage: ExperiencePresentationTraceStage
    let occurredAt: Date
    let monotonicTime: TimeInterval
}

/// Narrow sink used by the trigger and journey modules. Implementations own
/// synchronization so recording can happen at the synchronous API boundary.
protocol ExperiencePresentationTraceRecording: Sendable {
    var isEnabled: Bool { get }

    func record(
        attempt: ExperiencePresentationAttempt,
        stage: ExperiencePresentationTraceStage,
        timestamp: ExperiencePresentationTimestamp
    )
}

/// Attempt-scoped instrumentation passed explicitly through the loading and
/// runtime graph. It is internal qualification infrastructure, not customer
/// telemetry and not process-global state.
struct ExperiencePresentationTraceContext: Sendable {
    let attempt: ExperiencePresentationAttempt
    let recorder: ExperiencePresentationTraceRecording
    private let wallClock: @Sendable () -> Date
    private let monotonicClock: @Sendable () -> TimeInterval

    init(
        attempt: ExperiencePresentationAttempt,
        recorder: ExperiencePresentationTraceRecording,
        wallClock: @escaping @Sendable () -> Date = { Date() },
        monotonicClock: @escaping @Sendable () -> TimeInterval = {
            ExperiencePresentationTimestamp.monotonicNow()
        }
    ) {
        self.attempt = attempt
        self.recorder = recorder
        self.wallClock = wallClock
        self.monotonicClock = monotonicClock
    }

    @discardableResult
    func begin(
        _ work: ExperiencePresentationWork,
        attributes: [String: String] = [:]
    ) -> ExperiencePresentationTraceSpan {
        let timestamp = now()
        let span = ExperiencePresentationTraceSpan(
            id: UUID.v7().uuidString,
            work: work,
            startedAt: timestamp
        )
        recorder.record(
            attempt: attempt,
            stage: .workStarted(
                spanId: span.id,
                work: work,
                attributes: attributes
            ),
            timestamp: timestamp
        )
        return span
    }

    func recordTriggerAcceptedAndBeginRouting(
        at timestamp: ExperiencePresentationTimestamp
    ) {
        recorder.record(
            attempt: attempt,
            stage: .triggerAccepted,
            timestamp: timestamp
        )
        guard let span = attempt.triggerRoutingSpan else { return }
        recorder.record(
            attempt: attempt,
            stage: .workStarted(
                spanId: span.id,
                work: span.work,
                attributes: [:]
            ),
            timestamp: timestamp
        )
    }

    func recordPresentationRequested(
        experienceVersionId: String,
        route: ExperiencePresentationRoute,
        at timestamp: ExperiencePresentationTimestamp
    ) {
        recorder.record(
            attempt: attempt,
            stage: .presentationRequested(
                experienceVersionId: experienceVersionId,
                route: route
            ),
            timestamp: timestamp
        )
        if let span = attempt.triggerRoutingSpan {
            complete(span, at: timestamp)
        }
    }

    func completeTriggerRouting(
        at timestamp: ExperiencePresentationTimestamp? = nil
    ) {
        guard let span = attempt.triggerRoutingSpan else { return }
        complete(span, at: timestamp)
    }

    func completeDisplayPresentation(
        _ span: ExperiencePresentationTraceSpan,
        presentedMonotonicTime: TimeInterval,
        observedAt: ExperiencePresentationTimestamp,
        attributes: [String: String] = [:]
    ) {
        complete(
            span,
            at: .anchored(
                monotonicTime: presentedMonotonicTime,
                observedAt: observedAt
            ),
            attributes: attributes
        )
    }

    func complete(
        _ span: ExperiencePresentationTraceSpan,
        at timestamp: ExperiencePresentationTimestamp? = nil,
        attributes: [String: String] = [:]
    ) {
        let timestamp = timestamp ?? now()
        recorder.record(
            attempt: attempt,
            stage: .workCompleted(
                spanId: span.id,
                work: span.work,
                durationMilliseconds: durationMilliseconds(
                    from: span.startedAt,
                    to: timestamp
                ),
                attributes: attributes
            ),
            timestamp: timestamp
        )
    }

    func fail(
        _ span: ExperiencePresentationTraceSpan,
        error: Error,
        at timestamp: ExperiencePresentationTimestamp? = nil,
        attributes: [String: String] = [:]
    ) {
        let timestamp = timestamp ?? now()
        recorder.record(
            attempt: attempt,
            stage: .workFailed(
                spanId: span.id,
                work: span.work,
                durationMilliseconds: durationMilliseconds(
                    from: span.startedAt,
                    to: timestamp
                ),
                errorCode: Self.errorCode(for: error),
                attributes: attributes
            ),
            timestamp: timestamp
        )
    }

    func record(_ stage: ExperiencePresentationTraceStage) {
        recorder.record(attempt: attempt, stage: stage, timestamp: now())
    }

    private func now() -> ExperiencePresentationTimestamp {
        ExperiencePresentationTimestamp(
            wallClock: wallClock(),
            monotonicTime: monotonicClock()
        )
    }

    private func durationMilliseconds(
        from start: ExperiencePresentationTimestamp,
        to end: ExperiencePresentationTimestamp
    ) -> Double {
        max(0, (end.monotonicTime - start.monotonicTime) * 1_000)
    }

    static func errorCode(for error: Error) -> String {
        if let error = error as? ExperienceReleaseAcquisitionError {
            return error.contractCode
        }
        if let error = error as? ExperienceReleaseDescriptorAuthenticationError {
            return error.contractCode
        }
        if let error = error as? StoreKitError {
            return "storekit.\(String(describing: error))"
        }
        if error is CancellationError {
            return "cancelled"
        }
        return String(reflecting: type(of: error))
    }
}

@MainActor
protocol ExperiencePresentationTraceContextProviding: AnyObject {
    var presentationTraceContext: ExperiencePresentationTraceContext? { get }
}

/// Opaque presentation identity captured by the presentation host and handed
/// back to trace-aware delegates when that exact presentation finishes. The
/// host deliberately cannot derive or replace this identity from the current
/// delegate state during cleanup.
struct ExperiencePresentationTraceToken: Hashable, Sendable {
    let id: UUID
}

@MainActor
protocol ExperiencePresentationScopedTraceDelegate: ExperienceRuntimeDelegate {
    var activePresentationTraceToken: ExperiencePresentationTraceToken? { get }

    func experienceViewControllerDidBecomeReady(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    )

    func experienceViewControllerDidPresentShell(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    )

    func experienceViewControllerDidReveal(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64,
        traceToken: ExperiencePresentationTraceToken?
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String,
        traceToken: ExperiencePresentationTraceToken?
    )

    func experienceViewControllerDidFinishPresentation(
        _ controller: ExperienceViewController,
        traceToken: ExperiencePresentationTraceToken?
    )
}

extension ExperiencePresentationTraceRecording {
    func record(
        attempt: ExperiencePresentationAttempt,
        stage: ExperiencePresentationTraceStage,
        at wallClock: Date
    ) {
        record(
            attempt: attempt,
            stage: stage,
            timestamp: .now(wallClock: wallClock)
        )
    }
}

struct DisabledExperiencePresentationTrace {}

extension DisabledExperiencePresentationTrace: ExperiencePresentationTraceRecording {
    var isEnabled: Bool { false }

    func record(
        attempt: ExperiencePresentationAttempt,
        stage: ExperiencePresentationTraceStage,
        timestamp: ExperiencePresentationTimestamp
    ) {}
}

/// Qualification recorder. This is intentionally bounded by its owner rather
/// than installed globally; a harness injects one recorder for one run.
final class InMemoryExperiencePresentationTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [ExperiencePresentationTraceEvent] = []
    private var openSpanIDs: Set<String> = []

    func events(for attemptId: String? = nil) -> [ExperiencePresentationTraceEvent] {
        lock.withLock {
            guard let attemptId else { return recordedEvents }
            return recordedEvents.filter { $0.attempt.id == attemptId }
        }
    }

    func removeAll() {
        lock.withLock {
            recordedEvents.removeAll(keepingCapacity: true)
            openSpanIDs.removeAll(keepingCapacity: true)
        }
    }

    func qualificationSnapshot(
        for attemptId: String
    ) -> ExperiencePresentationQualificationSnapshot {
        let events = events(for: attemptId)
        return ExperiencePresentationQualificationSnapshot(
            attemptId: attemptId,
            triggerEvent: events.first?.attempt.triggerEvent,
            startedAt: events.first?.attempt.startedAt,
            startedAtMonotonicTime: events.first?.attempt.startedAtMonotonicTime,
            events: events.map(ExperiencePresentationQualificationEvent.init)
        )
    }
}

extension InMemoryExperiencePresentationTrace: ExperiencePresentationTraceRecording {
    var isEnabled: Bool { true }

    func record(
        attempt: ExperiencePresentationAttempt,
        stage: ExperiencePresentationTraceStage,
        timestamp: ExperiencePresentationTimestamp
    ) {
        lock.withLock {
            switch stage {
            case .workStarted(let spanId, _, _):
                guard openSpanIDs.insert(spanId).inserted else { return }
            case .workCompleted(let spanId, _, _, _),
                 .workFailed(let spanId, _, _, _, _):
                guard openSpanIDs.remove(spanId) != nil else { return }
            default:
                break
            }
            recordedEvents.append(
                ExperiencePresentationTraceEvent(
                    attempt: attempt,
                    stage: stage,
                    occurredAt: timestamp.wallClock,
                    monotonicTime: timestamp.monotonicTime
                )
            )
        }
    }
}

/// Stable, Codable export consumed by the in-repository qualification host.
/// Keeping this internal avoids adding diagnostics to the customer SDK API.
struct ExperiencePresentationQualificationSnapshot: Codable, Equatable, Sendable {
    let attemptId: String
    let triggerEvent: String?
    let startedAt: Date?
    let startedAtMonotonicTime: TimeInterval?
    let events: [ExperiencePresentationQualificationEvent]
}

struct ExperiencePresentationQualificationEvent: Codable, Equatable, Sendable {
    let attemptId: String
    let occurredAt: Date
    let monotonicTime: TimeInterval
    let stage: String
    let spanId: String?
    let work: String?
    let durationMilliseconds: Double?
    let errorCode: String?
    let attributes: [String: String]

    init(_ event: ExperiencePresentationTraceEvent) {
        attemptId = event.attempt.id
        occurredAt = event.occurredAt
        monotonicTime = event.monotonicTime
        switch event.stage {
        case .triggerAccepted:
            stage = "trigger_accepted"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [:]
        case .eventTracked(let eventId):
            stage = "event_tracked"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = ["event_id": eventId]
        case .journeyMatched(let journeyId):
            stage = "journey_matched"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = ["journey_id": journeyId]
        case .presentationRequested(let experienceVersionId, let route):
            stage = "presentation_requested"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [
                "experience_version_id": experienceVersionId,
                "route": route.rawValue
            ]
        case .runtimeReady:
            stage = "runtime_ready"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [:]
        case .shellPresented:
            stage = "shell_presented"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [:]
        case .revealed:
            stage = "revealed"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [:]
        case .firstPresentedDrawable(
            let screenId,
            let frameNumber,
            let pixels,
            let drawCalls,
            let provenance
        ):
            stage = "first_presented_drawable"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [
                "screen_id": screenId,
                "frame_number": String(frameNumber),
                "pixels": String(pixels),
                "draw_calls": String(drawCalls),
                "provenance": String(describing: provenance)
            ]
        case .firstAcceptedInput(let screenId, let eventCount):
            stage = "first_accepted_input"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [
                "screen_id": screenId,
                "event_count": String(eventCount)
            ]
        case .workStarted(let id, let kind, let fields):
            stage = "work_started"
            spanId = id
            work = kind.rawValue
            durationMilliseconds = nil
            errorCode = nil
            attributes = fields
        case .workCompleted(let id, let kind, let duration, let fields):
            stage = "work_completed"
            spanId = id
            work = kind.rawValue
            durationMilliseconds = duration
            errorCode = nil
            attributes = fields
        case .workFailed(let id, let kind, let duration, let code, let fields):
            stage = "work_failed"
            spanId = id
            work = kind.rawValue
            durationMilliseconds = duration
            errorCode = code
            attributes = fields
        case .presentationFailed(let route, let code):
            stage = "presentation_failed"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = code
            attributes = ["route": route.rawValue]
        case .presentationCleanupCompleted:
            stage = "presentation_cleanup_completed"
            spanId = nil
            work = nil
            durationMilliseconds = nil
            errorCode = nil
            attributes = [:]
        }
    }
}

enum ExperiencePresentationAttemptJourneyContext {
    private static let idKey = "_presentation_attempt_id"
    private static let triggerEventKey = "_presentation_attempt_trigger_event"
    private static let startedAtKey = "_presentation_attempt_started_at"
    private static let startedAtMonotonicTimeKey = "_presentation_attempt_started_at_monotonic"
    private static let bootSessionIdKey = "_presentation_attempt_boot_session_id"

    static func store(
        _ attempt: ExperiencePresentationAttempt,
        in journey: Journey,
        at now: Date
    ) async {
        await journey.update { state in
            store(attempt, in: &state, at: now)
        }
    }

    static func store(
        _ attempt: ExperiencePresentationAttempt,
        in state: inout JourneySnapshot,
        at now: Date
    ) {
        store(
            attempt,
            in: &state,
            at: now,
            bootSessionId: currentBootSessionId()
        )
    }

    static func store(
        _ attempt: ExperiencePresentationAttempt,
        in state: inout JourneySnapshot,
        at now: Date,
        bootSessionId: String?
    ) {
        state.context[idKey] = AnyCodable(attempt.id)
        state.context[triggerEventKey] = AnyCodable(attempt.triggerEvent)
        state.context[startedAtKey] = AnyCodable(attempt.startedAt.timeIntervalSince1970)
        if let startedAtMonotonicTime = attempt.startedAtMonotonicTime,
           let bootSessionId {
            state.context[startedAtMonotonicTimeKey] = AnyCodable(startedAtMonotonicTime)
            state.context[bootSessionIdKey] = AnyCodable(bootSessionId)
        } else {
            state.context.removeValue(forKey: startedAtMonotonicTimeKey)
            state.context.removeValue(forKey: bootSessionIdKey)
        }
        state.updatedAt = now
    }

    static func load(from journey: Journey) async -> ExperiencePresentationAttempt? {
        load(from: await journey.snapshot())
    }

    static func load(from state: JourneySnapshot) -> ExperiencePresentationAttempt? {
        load(from: state, bootSessionId: currentBootSessionId())
    }

    static func load(
        from state: JourneySnapshot,
        bootSessionId: String?
    ) -> ExperiencePresentationAttempt? {
        guard let id = state.context[idKey]?.value as? String,
              let triggerEvent = state.context[triggerEventKey]?.value as? String,
              let startedAt = timeInterval(state.context[startedAtKey]?.value) else {
            return nil
        }
        let storedBootSessionId = state.context[bootSessionIdKey]?.value as? String
        let persistedMonotonicTime = timeInterval(
            state.context[startedAtMonotonicTimeKey]?.value
        )
        return ExperiencePresentationAttempt(
            id: id,
            triggerEvent: triggerEvent,
            startedAt: Date(timeIntervalSince1970: startedAt),
            startedAtMonotonicTime: storedBootSessionId == bootSessionId
                ? persistedMonotonicTime
                : nil
        )
    }

    private static func currentBootSessionId() -> String? {
        #if canImport(Darwin)
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        return "\(bootTime.tv_sec):\(bootTime.tv_usec)"
        #else
        return nil
        #endif
    }

    private static func timeInterval(_ value: Any?) -> TimeInterval? {
        switch value {
        case let value as Double:
            value
        case let value as Float:
            TimeInterval(value)
        case let value as Int:
            TimeInterval(value)
        case let value as Int64:
            TimeInterval(value)
        case let value as UInt:
            TimeInterval(value)
        case let value as UInt64:
            TimeInterval(value)
        default:
            nil
        }
    }
}
