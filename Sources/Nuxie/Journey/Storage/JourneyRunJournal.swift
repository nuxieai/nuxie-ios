import CryptoKit
import Foundation

struct JourneyRun {
    /// Profile values that an admitted run still needs after delivery changes
    /// or disappears. Execution ownership is positional and cannot depend on
    /// the server continuing to advertise an already-started leg.
    struct ExecutionSnapshot: Codable, Sendable {
        let delivery: JourneyReleaseDelivery
        let assignments: ExactJSONObject<JourneyFactTable.Assignment?>
    }

    struct Park {
        let wakeAt: Date?
        let anchorAt: Date?
        var pendingEvent: JourneyControlExecutor.Event?
        var pendingResponsesChanged: Bool

        init(
            wakeAt: Date?,
            anchorAt: Date? = nil,
            pendingEvent: JourneyControlExecutor.Event? = nil,
            pendingResponsesChanged: Bool = false
        ) {
            self.wakeAt = wakeAt
            self.anchorAt = anchorAt
            self.pendingEvent = pendingEvent
            self.pendingResponsesChanged = pendingResponsesChanged
        }
    }
    struct Completion {
        let outcome: String
        let at: Date
    }
    struct ExperimentExposure: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case assigned
            case fallback
        }

        let experimentId: String
        let variantId: String
        let isHoldout: Bool
        let kind: Kind
        let eventId: String
        let selectedAt: Date
        /// The authenticated screen activation that first made this selected
        /// path visible. An unrelated later screen cannot expose it.
        var presentationScreenId: String?
        var shownAt: Date?
        var queued: Bool
    }

    struct PendingPresentationPublication: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            let name: String
            let properties: ExactJSONObject<JourneyReleaseJSONValue>
            let eventId: String
            let occurredAt: Date
        }

        let invocationId: String
        let source: ScreenEmissionSource
        let context: ArmedJourney.Context
        let responsesChanged: Bool
        let items: [Item]
    }

    let journeyId: String
    let generation: Int
    let reference: ArmedJourney.Reference
    let executionSnapshot: ExecutionSnapshot
    let artifactSHA256s: [String]
    let reentry: Journey.Reentry
    let startedAt: Date
    let isEnrollment: Bool
    let startedEventId: String
    let completedEventId: String
    var startedQueued = false
    var stepId: String
    var park: Park?
    var context: ArmedJourney.Context
    var outputs = ArmedJourney.Context(event: [:], responses: [:])
    /// Stable effect identities claimed before any host-visible side effect.
    /// A claimed effect is deliberately not a resume point: process death
    /// after this write abandons the run instead of replaying the effect.
    var effectReceipts: [String: String] = [:]
    /// Experiment decisions survive until a selected variant reaches a visible
    /// presentation. A stable event identity makes post-show reporting
    /// idempotent across retries and process recovery.
    var experimentExposures: [ExperimentExposure] = []
    /// A renderer invocation first records its answers and ordinary stable
    /// events here in one file replacement. EventLog then consumes these IDs;
    /// a crash can replay them without replaying the screen action.
    var pendingPresentationPublication: PendingPresentationPublication?
    var completion: Completion?

    var id: String { "\(journeyId):\(generation)" }
}

struct JourneyStateArmReceipt: Codable, Hashable, Sendable {
    let reference: ArmedJourney.Reference
    let binding: ArmedJourney.Binding
    let entryKind: JourneyEntryCondition.Kind

    init(_ arm: ArmedJourney) {
        reference = arm.reference
        binding = arm.binding
        entryKind = arm.entryCondition.type
    }
}

struct JourneyCheckmark {
    let journeyId: String
    let generation: Int
    let outcome: String
    let completedAt: Date
    /// Reentry counts new journeys, not completion time or continuation legs.
    let lastEnrollmentAt: Date?
    let reentry: Journey.Reentry
    let lastSeenLiveAt: Date

    init(
        journeyId: String,
        generation: Int,
        outcome: String,
        completedAt: Date,
        lastEnrollmentAt: Date?,
        reentry: Journey.Reentry,
        lastSeenLiveAt: Date
    ) {
        self.journeyId = journeyId
        self.generation = generation
        self.outcome = outcome
        self.completedAt = completedAt
        self.lastEnrollmentAt = lastEnrollmentAt
        self.reentry = reentry
        self.lastSeenLiveAt = lastSeenLiveAt
    }
}

enum JourneyJournalError {
    case invalidState, unsupportedVersion, storageLimit
}

/// The leg's retry state and reentry checklist share one atomic snapshot. The
/// existing event database remains the sole delivery queue. Nothing in this
/// journal reads, migrates, or deletes event history or commerce evidence.
struct JourneyRunJournal {
    fileprivate struct Snapshot {
        var schemaVersion = "nuxie.journey-journal.v1"
        var runs: [String: JourneyRun] = [:]
        var checklist: [String: JourneyCheckmark] = [:]
        var stateArmReceipts: Set<JourneyStateArmReceipt> = []
    }

    let distinctId: String
    private let root: URL
    private let file: URL
    private let releasePins: JourneyReleasePinStore
    private let revocationFile: URL
    private let lockScope: CacheFilesystemLockScope
    private let beforePersist: (@Sendable () throws -> Void)?
    /// A canonical profile may carry up to 24 MiB of admitted context. Keep
    /// the previous 16 MiB journal allowance as headroom for cursors,
    /// responses, receipts, and the reentry checklist.
    private static let maximumBytes = 40 * 1_024 * 1_024

    init(
        directory: URL,
        distinctId: String,
        storageScope: JourneyStorageScope = .testFixture,
        releasePinBudgetBytes: Int = JourneyReleasePinStore.defaultBudgetBytes,
        releasePinCountLimit: Int = JourneyReleasePinStore.defaultCountLimit,
        beforePersist: (@Sendable () throws -> Void)? = nil
    ) throws {
        self.distinctId = distinctId
        self.beforePersist = beforePersist
        let root = directory.appendingPathComponent("journey-journal-v1", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = storageScope.customerDigest(distinctId: distinctId)
        releasePins = JourneyReleasePinStore(
            journalRoot: root,
            customerDigest: digest,
            budgetBytes: releasePinBudgetBytes,
            countLimit: releasePinCountLimit
        )
        file = root.appendingPathComponent("\(digest).json")
        revocationFile = root.appendingPathComponent(
            "\(digest).revoked",
            isDirectory: false
        )
        lockScope = CacheFilesystemLockScope(cacheRootURL: root)
    }

    /// Called only after the arm and its signed release have been admitted.
    /// Persist before running any action, including emitting the started fact.
    func admit(
        arm: ArmedJourney,
        release: JourneyReleaseProfileEntry,
        artifactSource: JourneyReleaseArtifactSource? = nil,
        executionSnapshot: JourneyRun.ExecutionSnapshot,
        reentry: Journey.Reentry,
        entryStepId: String,
        at: Date,
        profileFence: JourneyProfileFence? = nil,
        profileFenceToken: JourneyProfileFenceToken? = nil,
        stateArmReceipt: JourneyStateArmReceipt? = nil,
        onAdmitted: @escaping @Sendable () -> Void = {}
    ) async throws -> JourneyRun? {
        guard (profileFence == nil) == (profileFenceToken == nil) else {
            throw JourneyJournalError.invalidState
        }
        guard Self.pin(release, matches: arm.reference) else {
            throw JourneyJournalError.invalidState
        }
        guard artifactSource?.descriptorSHA256
                == arm.reference.descriptorSha256
                || artifactSource == nil else {
            throw JourneyJournalError.invalidState
        }
        let file = file
        let root = root
        let releasePins = releasePins
        let revocationFile = revocationFile
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            // Another customer instance may have removed this still-empty
            // directory as an orphan before this journal's first admission.
            // Recreate it inside the root transaction before cleanup/write.
            try releasePins.ensureCustomerDirectory()
            guard !FileManager.default.fileExists(atPath: revocationFile.path) else {
                return nil
            }
            var state = try Self.load(file)
            if let stateArmReceipt,
               state.stateArmReceipts.contains(stateArmReceipt) {
                return nil
            }
            try releasePins.removeUnreferenced(Self.pinReferences(state))
            try releasePins.removeGlobalOrphans(journalRoot: root) {
                Self.pinReferences(try Self.load($0))
            }
            let previous = state.checklist[arm.reference.experienceId]
            let journeyId: String
            let generation: Int
            switch arm.binding.type {
            case .new:
                let latest = state.runs.values.filter {
                    $0.reference.experienceId == arm.reference.experienceId && $0.isEnrollment
                }.map(\.startedAt).max()
                let last = [latest, previous?.lastEnrollmentAt].compactMap { $0 }.max()
                if let last {
                    switch reentry.type {
                    case .oneTime: return nil
                    case .oncePerWindow:
                        guard let window = reentry.windowSeconds, window > 0 else { throw JourneyJournalError.invalidState }
                        if at.timeIntervalSince(last) < Double(window) { return nil }
                    case .everyTime: break
                    }
                }
                journeyId = UUID.v7().uuidString.lowercased()
                generation = 0
            case .continuation:
                guard let boundId = arm.binding.journeyId, let boundGeneration = arm.binding.generation else {
                    throw JourneyJournalError.invalidState
                }
                journeyId = boundId
                generation = boundGeneration
                if previous?.journeyId == journeyId, let previous, previous.generation >= generation { return nil }
            }
            let runId = "\(journeyId):\(generation)"
            guard state.runs[runId] == nil else { return nil }
            guard state.runs.count < 1024 else { throw JourneyJournalError.storageLimit }
            let inheritedArtifactSHA256s = state.runs.values.first(where: {
                $0.reference.descriptorSha256
                    == arm.reference.descriptorSha256
            })?.artifactSHA256s ?? []
            let preparedPins = try releasePins.prepareAdmission(
                release: release,
                descriptorSHA256: arm.reference.descriptorSha256,
                artifactSource: artifactSource,
                inheritedArtifactSHA256s: inheritedArtifactSHA256s
            )
            let run = JourneyRun(
                journeyId: journeyId,
                generation: generation,
                reference: arm.reference,
                executionSnapshot: executionSnapshot,
                artifactSHA256s: preparedPins.artifactSHA256s,
                reentry: reentry,
                startedAt: at,
                isEnrollment: arm.binding.type == .new,
                startedEventId: UUID.v7().uuidString.lowercased(),
                completedEventId: UUID.v7().uuidString.lowercased(),
                stepId: entryStepId,
                context: arm.context
            )
            state.runs[run.id] = run
            if let stateArmReceipt {
                guard state.stateArmReceipts.insert(stateArmReceipt).inserted else {
                    preparedPins.rollback()
                    return nil
                }
            }
            do {
                if let profileFence, let profileFenceToken {
                    guard try profileFence.performIfCurrent(
                        profileFenceToken,
                        { () -> Void in
                            try beforePersist?()
                            try Self.persist(state, to: file)
                            onAdmitted()
                        }
                    ) != nil else {
                        preparedPins.rollback()
                        return nil
                    }
                } else {
                    try beforePersist?()
                    try Self.persist(state, to: file)
                    onAdmitted()
                }
                return run
            } catch {
                preparedPins.rollback()
                throw error
            }
        }
    }

    func runs() async throws -> [JourneyRun] {
        try await read { $0.runs.values.sorted { $0.startedEventId < $1.startedEventId } }
    }

    func releasePin(
        descriptorSHA256: String
    ) async throws -> JourneyReleaseProfileEntry? {
        let file = file
        let releasePins = releasePins
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            let state = try Self.load(file)
            guard state.runs.values.contains(where: {
                $0.reference.descriptorSha256 == descriptorSHA256
            }) else {
                return nil
            }
            return try releasePins.release(
                descriptorSHA256: descriptorSHA256
            )
        }
    }

    func pinnedArtifacts(
        forRunId runId: String
    ) async throws -> JourneyPinnedReleaseArtifacts? {
        let file = file
        let releasePins = releasePins
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            let state = try Self.load(file)
            guard let run = state.runs[runId] else { return nil }
            return try releasePins.pinnedArtifacts(
                sha256s: run.artifactSHA256s
            )
        }
    }

    func checkmark(experienceId: String) async throws -> JourneyCheckmark? {
        try await read { $0.checklist[experienceId] }
    }

    func retainStateArmReceipts(
        _ allowed: Set<JourneyStateArmReceipt>
    ) async throws {
        try await update { state in
            state.stateArmReceipts = Set(
                state.stateArmReceipts.filter(allowed.contains)
            )
        }
    }

    /// Reopens one state latch without disturbing receipts for other entry
    /// kinds. The filesystem transaction keeps multiple SDK instances from
    /// starting the same arm when they observe the latch transition together.
    func clearStateArmReceipts(
        entryKind: JourneyEntryCondition.Kind
    ) async throws {
        try await update { state in
            state.stateArmReceipts = Set(
                state.stateArmReceipts.filter {
                    $0.entryKind != entryKind
                }
            )
        }
    }

    /// Keep checkmarks while an experience is delivered, then for its authored
    /// reentry window.
    func retainCheckmarks(
        liveExperiences: [String: Journey.Reentry],
        at: Date
    ) async throws {
        try await update { state in
            for (experienceId, var checkmark) in state.checklist {
                if let livePolicy = liveExperiences[experienceId] {
                    checkmark = .init(
                        journeyId: checkmark.journeyId,
                        generation: checkmark.generation,
                        outcome: checkmark.outcome,
                        completedAt: checkmark.completedAt,
                        lastEnrollmentAt: checkmark.lastEnrollmentAt,
                        reentry: livePolicy,
                        lastSeenLiveAt: at
                    )
                    state.checklist[experienceId] = checkmark
                    continue
                }
                switch checkmark.reentry.type {
                case .oncePerWindow:
                    guard let window = checkmark.reentry.windowSeconds,
                          window > 0 else {
                        state.checklist.removeValue(forKey: experienceId)
                        continue
                    }
                    if at.timeIntervalSince(checkmark.lastSeenLiveAt)
                        >= Double(window) {
                        state.checklist.removeValue(forKey: experienceId)
                    }
                case .oneTime, .everyTime:
                    state.checklist.removeValue(forKey: experienceId)
                }
            }
        }
    }

    func recordResponses(_ id: String, values: ExactJSONObject<JourneyReleaseJSONValue>) async throws {
        try await update { state in
            guard var run = state.runs[id], run.completion == nil else { throw JourneyJournalError.invalidState }
            let responses = run.context.responses.merging(values) { _, new in new }
            run.context = .init(event: run.context.event, responses: responses)
            state.runs[id] = run
        }
    }

    @discardableResult
    func stagePresentationPublication(
        _ id: String,
        expectedStepId: String,
        expectedCheckpoint: JourneyControlExecutor.Checkpoint?,
        publication: JourneyRun.PendingPresentationPublication,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        let expectedPark = expectedCheckpoint.map {
            JourneyRun.Park(
                wakeAt: JourneyTime.date($0.wakeAtMillis),
                anchorAt: JourneyTime.date($0.anchorAtMillis)
            )
        }
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id],
                  run.startedQueued,
                  run.completion == nil,
                  run.stepId == expectedStepId,
                  run.park == expectedPark else {
                throw JourneyJournalError.invalidState
            }
            if let pending = run.pendingPresentationPublication {
                guard pending == publication else {
                    throw JourneyJournalError.invalidState
                }
                return
            }
            run.context = publication.context
            run.pendingPresentationPublication = publication
            state.runs[id] = run
        }
        return try await updateIfCurrent(admission, mutation) != nil
    }

    @discardableResult
    func clearPresentationPublication(
        _ id: String,
        invocationId: String,
        retainingResponsesChanged: Bool = false,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id], run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            guard let pending = run.pendingPresentationPublication else {
                return
            }
            guard pending.invocationId == invocationId else {
                throw JourneyJournalError.invalidState
            }
            if retainingResponsesChanged {
                guard var park = run.park else {
                    throw JourneyJournalError.invalidState
                }
                park.pendingResponsesChanged = true
                run.park = park
            }
            run.pendingPresentationPublication = nil
            state.runs[id] = run
        }
        return try await updateIfCurrent(admission, mutation) != nil
    }

    /// Persist one executor transition before another step or effect runs.
    @discardableResult
    func transition(
        _ id: String,
        stepId: String,
        context: ArmedJourney.Context,
        checkpoint: JourneyControlExecutor.Checkpoint? = nil,
        experimentExposure: JourneyRun.ExperimentExposure? = nil,
        clearingPresentationPublication invocationId: String? = nil,
        admission: JourneyCommitAdmission? = nil
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id], run.startedQueued, run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            // A receipt belongs to one visit to an effect cursor. Once that
            // visit advances, a later loop back must claim a fresh identity.
            run.effectReceipts.removeValue(forKey: run.stepId)
            run.stepId = stepId
            run.context = context
            if let experimentExposure,
               !run.experimentExposures.contains(where: {
                   $0.experimentId == experimentExposure.experimentId
               }) {
                run.experimentExposures.append(experimentExposure)
            }
            if let invocationId {
                guard run.pendingPresentationPublication?.invocationId
                    == invocationId else {
                    throw JourneyJournalError.invalidState
                }
                run.pendingPresentationPublication = nil
            }
            run.park = checkpoint.map {
                .init(
                    wakeAt: JourneyTime.date($0.wakeAtMillis),
                    anchorAt: JourneyTime.date($0.anchorAtMillis)
                )
            }
            state.runs[id] = run
        }
        if let admission {
            return try await updateIfCurrent(admission, mutation) != nil
        }
        try await update(mutation)
        return true
    }

    @discardableResult
    func bindExperimentExposures(
        _ id: String,
        to screenId: String,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        try await updateIfCurrent(admission) { state in
            guard var run = state.runs[id], run.startedQueued,
                  run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            for index in run.experimentExposures.indices
            where !run.experimentExposures[index].queued
                && run.experimentExposures[index].shownAt == nil
                && run.experimentExposures[index].presentationScreenId == nil {
                run.experimentExposures[index].presentationScreenId = screenId
            }
            state.runs[id] = run
            return true
        } ?? false
    }

    @discardableResult
    func markExperimentExposuresShown(
        _ id: String,
        screenId: String,
        at: Date,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        try await updateIfCurrent(admission) { state in
            guard var run = state.runs[id], run.startedQueued,
                  run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            for index in run.experimentExposures.indices
            where !run.experimentExposures[index].queued
                && run.experimentExposures[index].presentationScreenId == screenId
                && run.experimentExposures[index].shownAt == nil {
                run.experimentExposures[index].shownAt = at
            }
            state.runs[id] = run
            return true
        } ?? false
    }

    func markExperimentExposureQueued(
        _ id: String,
        eventId: String
    ) async throws {
        try await update { state in
            guard var run = state.runs[id],
                  let index = run.experimentExposures.firstIndex(where: {
                      $0.eventId == eventId
                  }), run.experimentExposures[index].shownAt != nil else {
                throw JourneyJournalError.invalidState
            }
            run.experimentExposures[index].queued = true
            state.runs[id] = run
        }
    }

    @discardableResult
    func park(
        _ id: String,
        stepId: String,
        until: Date?,
        admission: JourneyCommitAdmission? = nil
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id], run.startedQueued, run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            run.stepId = stepId
            run.park = .init(wakeAt: until)
            state.runs[id] = run
        }
        if let admission {
            return try await updateIfCurrent(admission, mutation) != nil
        }
        try await update(mutation)
        return true
    }

    /// Retains the first event that satisfies a parked rendered wait while the
    /// host is backgrounded. The park remains the resumable checkpoint until
    /// foreground presentation admission opens again.
    @discardableResult
    func stageParkedEvent(
        _ id: String,
        expectedStepId: String,
        expectedCheckpoint: JourneyControlExecutor.Checkpoint,
        event: JourneyControlExecutor.Event,
        admission: JourneyCommitAdmission
    ) async throws -> Bool {
        let expectedWakeAt = JourneyTime.date(
            expectedCheckpoint.wakeAtMillis
        )
        let expectedAnchorAt = JourneyTime.date(
            expectedCheckpoint.anchorAtMillis
        )
        return try await updateIfCurrent(admission) { state in
            guard var run = state.runs[id],
                  run.startedQueued,
                  run.completion == nil,
                  run.stepId == expectedStepId,
                  var park = run.park,
                  park.wakeAt == expectedWakeAt,
                  park.anchorAt == expectedAnchorAt else {
                throw JourneyJournalError.invalidState
            }
            if park.pendingEvent == nil {
                park.pendingEvent = event
                run.park = park
                state.runs[id] = run
            }
            return true
        } ?? false
    }

    /// Persist a stable effect identity before dispatch. Re-entering an
    /// explicitly parked unsupported cursor reuses the same identity, while a
    /// process death after this claim is recovered as abandonment.
    func claimEffect(_ id: String, stepId: String) async throws -> String {
        try await update { state in
            guard var run = state.runs[id],
                  run.startedQueued,
                  run.completion == nil,
                  run.stepId == stepId else {
                throw JourneyJournalError.invalidState
            }
            if let existing = run.effectReceipts[stepId] {
                run.park = nil
                state.runs[id] = run
                return existing
            }
            let effectId = UUID.v7().uuidString.lowercased()
            run.effectReceipts[stepId] = effectId
            run.park = nil
            state.runs[id] = run
            return effectId
        }
    }

    /// Called once on process launch, before any leg executes. Expired waits
    /// remain parked so the executor can evaluate them against current facts.
    func recover(at: Date) async throws -> [JourneyRun] {
        let root = root
        let file = file
        let releasePins = releasePins
        let revocationFile = revocationFile
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            try releasePins.ensureCustomerDirectory()
            var state = try Self.load(file)
            let revoked = FileManager.default.fileExists(
                atPath: revocationFile.path
            )
            var pinsByDigest: [String: JourneyReleaseProfileEntry] = [:]
            var invalidPinDigests: Set<String> = []
            for (id, var run) in state.runs where run.completion == nil {
                let digest = run.reference.descriptorSha256
                let pin: JourneyReleaseProfileEntry?
                if invalidPinDigests.contains(digest) {
                    pin = nil
                } else if let cached = pinsByDigest[digest] {
                    pin = cached
                } else if let loaded = try? releasePins.release(
                    descriptorSHA256: digest
                ) {
                    pinsByDigest[digest] = loaded
                    pin = loaded
                } else {
                    invalidPinDigests.insert(digest)
                    pin = nil
                }
                if revoked || run.park == nil
                    || pin.map({ Self.pin($0, matches: run.reference) }) != true {
                    let eventOutputs = run.outputs.event
                    let pendingPresentationPublication =
                        run.pendingPresentationPublication
                    Self.finish(
                        &run,
                        outcome: "abandoned",
                        at: at,
                        eventOutputs: eventOutputs,
                        responseOutputs: run.context.responses
                    )
                    // The process break terminates execution, but renderer
                    // events staged before the break remain an ordinary-event
                    // outbox. Startup publishes them before the terminal
                    // report removes this run; their stable IDs make retries
                    // idempotent without replaying the screen action.
                    run.pendingPresentationPublication =
                        pendingPresentationPublication
                    state.runs[id] = run
                }
            }
            try beforePersist?()
            try Self.persist(state, to: file)
            do {
                try releasePins.removeUnreferenced(Self.pinReferences(state))
            } catch {
                // The recovered run state is already authoritative. Pin
                // pruning is maintenance and must not prevent the caller from
                // reporting newly persisted abandonment completions.
                LogWarning(
                    "JourneyRunJournal: failed to prune recovered release pins: \(error)"
                )
            }
            return state.runs.values.filter {
                $0.park != nil && $0.completion == nil
            }
                .sorted { $0.startedEventId < $1.startedEventId }
        }
    }

    /// Identity teardown and total cutover have stronger semantics than a
    /// process restart: parked runs belong to the departing authority too and
    /// must report abandonment instead of remaining resumable forever.
    func abandonAll(at: Date) async throws {
        let root = root
        let file = file
        let revocationFile = revocationFile
        let beforePersist = beforePersist
        try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            try Data("revoked\n".utf8).write(
                to: revocationFile,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            var state = try Self.load(file)
            for (id, var run) in state.runs where run.completion == nil {
                let eventOutputs = run.outputs.event
                Self.finish(
                    &run,
                    outcome: "abandoned",
                    at: at,
                    eventOutputs: eventOutputs,
                    responseOutputs: run.context.responses
                )
                state.runs[id] = run
            }
            // Authority teardown also retires state-latch admissions. A later
            // delivery of the same arm belongs to a new profile authority and
            // must be able to start when its state is satisfied.
            state.stateArmReceipts = []
            try beforePersist?()
            try Self.persist(state, to: file)
        }
    }

    /// Remove the admission tombstone only after reporting retired every run.
    /// A failed report leaves the marker in place for the next launch.
    func finalizeRevocation() async throws -> Bool {
        let root = root
        let file = file
        let revocationFile = revocationFile
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            guard FileManager.default.fileExists(atPath: revocationFile.path) else {
                return true
            }
            guard try Self.load(file).runs.isEmpty else { return false }
            try FileManager.default.removeItem(at: revocationFile)
            return true
        }
    }

    /// Consume the only resumable checkpoint before running its continuation.
    /// The caller must first establish that this wait should wake now.
    func resumeParked(
        _ id: String,
        admission: JourneyCommitAdmission
    ) async throws -> JourneyRun? {
        let file = file
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            var state = try Self.load(file)
            guard var run = state.runs[id], run.startedQueued, run.park != nil, run.completion == nil else {
                throw JourneyJournalError.invalidState
            }
            run.park = nil
            state.runs[id] = run
            guard try admission.commitJournalIfCurrent({ () -> Void in
                try beforePersist?()
                try Self.persist(state, to: file)
            }) != nil else { return nil }
            return run
        }
    }

    @discardableResult
    func complete(
        _ id: String,
        outcome: String,
        at: Date,
        eventOutputs: ExactJSONObject<JourneyReleaseJSONValue> = [:],
        responseOutputs: ExactJSONObject<JourneyReleaseJSONValue> = [:],
        admission: JourneyCommitAdmission? = nil
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id] else { throw JourneyJournalError.invalidState }
            // A retry cannot rewrite the outcome, outputs, or occurrence time.
            guard run.completion == nil else { return }
            guard !outcome.isEmpty, outcome.utf16.count <= 256 else { throw JourneyJournalError.invalidState }
            // These fields belong to the selected terminal boundary. Publish
            // them with its outcome so a crash cannot send them as abandoned.
            Self.finish(
                &run,
                outcome: outcome,
                at: at,
                eventOutputs: eventOutputs,
                responseOutputs: responseOutputs
            )
            state.runs[id] = run
        }
        if let admission {
            return try await updateIfCurrent(admission, mutation) != nil
        }
        try await update(mutation)
        return true
    }

    func markStartedQueued(_ run: JourneyRun) async throws {
        try await update { state in
            guard var current = state.runs[run.id], current.startedEventId == run.startedEventId else { return }
            current.startedQueued = true
            state.runs[run.id] = current
        }
    }

    func markCompletionQueued(_ run: JourneyRun) async throws {
        try await update(cleanupReleasePins: true) { state in
            guard let current = state.runs[run.id], current.completedEventId == run.completedEventId else { return }
            guard current.startedQueued, let completion = current.completion else { throw JourneyJournalError.invalidState }
            let experienceId = current.reference.experienceId
            let previous = state.checklist[experienceId]
            let lastEnrollment = [previous?.lastEnrollmentAt, current.isEnrollment ? current.startedAt : nil].compactMap { $0 }.max()
            let newer = previous.flatMap { $0.journeyId == current.journeyId && $0.generation > current.generation ? $0 : nil }
            state.checklist[experienceId] = .init(journeyId: current.journeyId, generation: newer?.generation ?? current.generation,
                                                 outcome: newer?.outcome ?? completion.outcome, completedAt: newer?.completedAt ?? completion.at,
                                                 lastEnrollmentAt: lastEnrollment,
                                                 reentry: newer?.reentry ?? current.reentry,
                                                 lastSeenLiveAt: newer?.lastSeenLiveAt ?? completion.at)
            state.runs.removeValue(forKey: current.id)
        }
    }

    private static func pin(
        _ release: JourneyReleaseProfileEntry,
        matches reference: ArmedJourney.Reference
    ) -> Bool {
        release.envelope.descriptorSha256 == reference.descriptorSha256
            && release.locator.experienceId == reference.experienceId
            && release.locator.experienceVersionId == reference.versionId
            && release.locator.legId == reference.legId
    }

    private static func finish(
        _ run: inout JourneyRun,
        outcome: String,
        at: Date,
        eventOutputs: ExactJSONObject<JourneyReleaseJSONValue>,
        responseOutputs: ExactJSONObject<JourneyReleaseJSONValue>
    ) {
        run.outputs = .init(
            event: eventOutputs,
            responses: responseOutputs
        )
        // Execution context is no longer needed once the terminal report owns
        // its selected outputs. Moving rather than copying keeps a
        // maximum-size canonical context within the journal budget.
        run.context = .init(event: [:], responses: [:])
        run.pendingPresentationPublication = nil
        run.completion = .init(outcome: outcome, at: at)
    }

    private func read<Value: Sendable>(_ operation: @escaping @Sendable (Snapshot) throws -> Value) async throws -> Value {
        let file = file
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(to: file, lockScope: lockScope) {
            try operation(Self.load(file))
        }
    }

    private func update<Value: Sendable>(
        cleanupReleasePins: Bool = false,
        _ operation: @escaping @Sendable (inout Snapshot) throws -> Value
    ) async throws -> Value {
        let file = file
        let releasePins = releasePins
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(to: file, lockScope: lockScope) {
            var state = try Self.load(file)
            let value = try operation(&state)
            try beforePersist?()
            try Self.persist(state, to: file)
            if cleanupReleasePins {
                do {
                    try releasePins.removeUnreferenced(
                        Self.pinReferences(state)
                    )
                } catch {
                    // The journal replacement is the terminal authority. Pin
                    // pruning is reclaimable maintenance and cannot turn a
                    // committed run deletion into a failed completion.
                    LogWarning(
                        "JourneyRunJournal: failed to prune retired release pins: \(error)"
                    )
                }
            }
            return value
        }
    }

    private func updateIfCurrent<Value: Sendable>(
        _ admission: JourneyCommitAdmission,
        _ operation: @escaping @Sendable (inout Snapshot) throws -> Value
    ) async throws -> Value? {
        let file = file
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            var state = try Self.load(file)
            let value = try operation(&state)
            return try admission.commitJournalIfCurrent {
                try beforePersist?()
                try Self.persist(state, to: file)
                return value
            }
        }
    }

    private static func persist(_ state: Snapshot, to file: URL) throws {
        let bytes = try ExactJSONCodec.encode(state)
        guard bytes.count <= maximumBytes else {
            throw JourneyJournalError.storageLimit
        }
        try bytes.write(
            to: file,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private static func pinReferences(
        _ state: Snapshot
    ) -> JourneyReleasePinReferences {
        JourneyReleasePinReferences(
            descriptorSHA256s: Set(state.runs.values.map {
                $0.reference.descriptorSha256
            }),
            artifactSHA256s: Set(state.runs.values.flatMap(\.artifactSHA256s))
        )
    }

    private static func load(_ file: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let bytes = try BoundedFileIO.read(at: file, maximumBytes: maximumBytes).data
        let state = try ExactJSONCodec.decode(Snapshot.self, from: bytes)
        guard state.schemaVersion == "nuxie.journey-journal.v1" else { throw JourneyJournalError.unsupportedVersion }
        return state
    }

}

extension JourneyRun: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case journeyId
        case generation
        case reference
        case executionSnapshot
        case artifactSHA256s
        case reentry
        case startedAt
        case isEnrollment
        case startedEventId
        case completedEventId
        case startedQueued
        case stepId
        case park
        case context
        case outputs
        case effectReceipts
        case experimentExposures
        case pendingPresentationPublication
        case completion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        journeyId = try container.decode(String.self, forKey: .journeyId)
        generation = try container.decode(Int.self, forKey: .generation)
        reference = try container.decode(ArmedJourney.Reference.self, forKey: .reference)
        executionSnapshot = try container.decode(
            ExecutionSnapshot.self,
            forKey: .executionSnapshot
        )
        artifactSHA256s = try container.decode(
            [String].self,
            forKey: .artifactSHA256s
        )
        guard artifactSHA256s == artifactSHA256s.sorted(),
              Set(artifactSHA256s).count == artifactSHA256s.count,
              artifactSHA256s.allSatisfy(
                JourneyReleasePinStore.isLowercaseSHA256
              ) else {
            throw JourneyJournalError.invalidState
        }
        reentry = try container.decode(
            Journey.Reentry.self,
            forKey: .reentry
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        isEnrollment = try container.decode(Bool.self, forKey: .isEnrollment)
        startedEventId = try container.decode(String.self, forKey: .startedEventId)
        completedEventId = try container.decode(String.self, forKey: .completedEventId)
        startedQueued = try container.decode(Bool.self, forKey: .startedQueued)
        stepId = try container.decode(String.self, forKey: .stepId)
        park = try container.decodeIfPresent(Park.self, forKey: .park)
        context = try container.decode(ArmedJourney.Context.self, forKey: .context)
        outputs = try container.decode(
            ArmedJourney.Context.self,
            forKey: .outputs
        )
        effectReceipts = try container.decode(
            [String: String].self,
            forKey: .effectReceipts
        )
        experimentExposures = try container.decode(
            [ExperimentExposure].self,
            forKey: .experimentExposures
        )
        pendingPresentationPublication = try container.decodeIfPresent(
            PendingPresentationPublication.self,
            forKey: .pendingPresentationPublication
        )
        completion = try container.decodeIfPresent(Completion.self, forKey: .completion)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(journeyId, forKey: .journeyId)
        try container.encode(generation, forKey: .generation)
        try container.encode(reference, forKey: .reference)
        try container.encode(
            executionSnapshot,
            forKey: .executionSnapshot
        )
        try container.encode(artifactSHA256s, forKey: .artifactSHA256s)
        try container.encode(reentry, forKey: .reentry)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(isEnrollment, forKey: .isEnrollment)
        try container.encode(startedEventId, forKey: .startedEventId)
        try container.encode(completedEventId, forKey: .completedEventId)
        try container.encode(startedQueued, forKey: .startedQueued)
        try container.encode(stepId, forKey: .stepId)
        try container.encodeIfPresent(park, forKey: .park)
        try container.encode(context, forKey: .context)
        try container.encode(outputs, forKey: .outputs)
        try container.encode(effectReceipts, forKey: .effectReceipts)
        try container.encode(experimentExposures, forKey: .experimentExposures)
        try container.encodeIfPresent(
            pendingPresentationPublication,
            forKey: .pendingPresentationPublication
        )
        try container.encodeIfPresent(completion, forKey: .completion)
    }
}
extension JourneyRun.Park: Codable, Equatable, Sendable {}
extension JourneyRun.Completion: Codable, Sendable {}
extension JourneyCheckmark: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case journeyId
        case generation
        case outcome
        case completedAt
        case lastEnrollmentAt
        case reentry
        case lastSeenLiveAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            journeyId: try container.decode(String.self, forKey: .journeyId),
            generation: try container.decode(Int.self, forKey: .generation),
            outcome: try container.decode(String.self, forKey: .outcome),
            completedAt: try container.decode(Date.self, forKey: .completedAt),
            lastEnrollmentAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastEnrollmentAt
            ),
            reentry: try container.decode(
                Journey.Reentry.self,
                forKey: .reentry
            ),
            lastSeenLiveAt: try container.decode(
                Date.self,
                forKey: .lastSeenLiveAt
            )
        )
    }
}
extension JourneyJournalError: Error {}
extension JourneyRunJournal: Sendable {}
extension JourneyRunJournal.Snapshot: Codable {}
