import CryptoKit
import Foundation

struct DeviceLegRun {
    struct Park {
        let wakeAt: Date?
        let anchorAt: Date?

        init(wakeAt: Date?, anchorAt: Date? = nil) {
            self.wakeAt = wakeAt
            self.anchorAt = anchorAt
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
            case invalidAssignment
        }

        let experimentId: String
        let variantId: String
        let assignedVariantId: String?
        let isHoldout: Bool
        let kind: Kind
        let eventId: String
        let selectedAt: Date
        var shownAt: Date?
        var queued: Bool
    }

    struct PendingPresentationPublication: Codable, Equatable, Sendable {
        struct Item: Codable, Equatable, Sendable {
            let name: String
            let properties: ExactJSONObject<ExperienceReleaseJSONValue>
            let eventId: String
            let occurredAt: Date
        }

        let invocationId: String
        let context: ArmedDeviceLeg.Context
        let items: [Item]
    }

    let journeyId: String
    let generation: Int
    let reference: ArmedDeviceLeg.Reference
    let artifactSHA256s: [String]
    let reentry: DeviceLeg.Reentry?
    let startedAt: Date
    let isEnrollment: Bool
    let startedEventId: String
    let completedEventId: String
    var startedQueued = false
    var stepId: String
    var park: Park?
    var context: ArmedDeviceLeg.Context
    var outputs = ArmedDeviceLeg.Context(event: [:], responses: [:])
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

struct DeviceLegStateArmReceipt: Codable, Hashable, Sendable {
    let reference: ArmedDeviceLeg.Reference
    let binding: ArmedDeviceLeg.Binding
    let entryKind: DeviceLegEntryCondition.Kind

    init(_ arm: ArmedDeviceLeg) {
        reference = arm.reference
        binding = arm.binding
        entryKind = arm.entryCondition.type
    }
}

struct DeviceLegCheckmark {
    let journeyId: String
    let generation: Int
    let outcome: String
    let completedAt: Date
    /// Reentry counts new journeys, not completion time or continuation legs.
    let lastEnrollmentAt: Date?
    /// Optional for journals written before retention metadata was added.
    let reentry: DeviceLeg.Reentry?
    let lastSeenLiveAt: Date?

    init(
        journeyId: String,
        generation: Int,
        outcome: String,
        completedAt: Date,
        lastEnrollmentAt: Date?,
        reentry: DeviceLeg.Reentry? = nil,
        lastSeenLiveAt: Date? = nil
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

enum DeviceLegJournalError {
    case invalidState, unsupportedVersion, storageLimit
}

/// The leg's retry state and reentry checklist share one atomic snapshot. The
/// existing event database remains the sole delivery queue. Nothing in this
/// journal reads, migrates, or deletes event history or commerce evidence.
struct DeviceLegRunJournal {
    fileprivate struct Snapshot {
        var schemaVersion = "nuxie.device-leg-journal.v1"
        var runs: [String: DeviceLegRun] = [:]
        var checklist: [String: DeviceLegCheckmark] = [:]
        /// Optional preserves decoding of existing v1 snapshots.
        var stateArmReceipts: Set<DeviceLegStateArmReceipt>? = nil
    }

    let distinctId: String
    private let root: URL
    private let file: URL
    private let releasePinRoot: URL
    private let releasePinDirectory: URL
    private let revocationFile: URL
    private let lockScope: CacheFilesystemLockScope
    private let releasePinBudgetBytes: Int
    private let releasePinCountLimit: Int
    private let beforePersist: (@Sendable () throws -> Void)?
    /// A canonical profile may carry up to 24 MiB of admitted context. Keep
    /// the previous 16 MiB journal allowance as headroom for cursors,
    /// responses, receipts, and the reentry checklist.
    private static let maximumBytes = 40 * 1_024 * 1_024
    private static let maximumReleasePinBytes =
        ExperienceReleaseDescriptorLimits.profileBytes
    private static let defaultReleasePinBudgetBytes = 256 * 1_024 * 1_024
    private static let defaultReleasePinCountLimit = 1_024

    init(
        directory: URL,
        distinctId: String,
        storageScope: DeviceLegStorageScope = .testFixture,
        releasePinBudgetBytes: Int = Self.defaultReleasePinBudgetBytes,
        releasePinCountLimit: Int = Self.defaultReleasePinCountLimit,
        beforePersist: (@Sendable () throws -> Void)? = nil
    ) throws {
        self.distinctId = distinctId
        self.releasePinBudgetBytes = max(0, releasePinBudgetBytes)
        self.releasePinCountLimit = max(0, releasePinCountLimit)
        self.beforePersist = beforePersist
        let root = directory.appendingPathComponent("device-leg-journal-v1", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = storageScope.customerDigest(distinctId: distinctId)
        releasePinRoot = root.appendingPathComponent(
            "release-pins",
            isDirectory: true
        )
        releasePinDirectory = releasePinRoot
            .appendingPathComponent(digest, isDirectory: true)
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
        arm: ArmedDeviceLeg,
        release: DeviceLegReleaseProfileEntry,
        artifactSource: DeviceLegReleaseArtifactSource? = nil,
        reentry: DeviceLeg.Reentry,
        entryStepId: String,
        at: Date,
        profileFence: DeviceLegProfileFence? = nil,
        profileFenceToken: DeviceLegProfileFenceToken? = nil,
        stateArmReceipt: DeviceLegStateArmReceipt? = nil,
        onAdmitted: @escaping @Sendable () -> Void = {}
    ) async throws -> DeviceLegRun? {
        guard (profileFence == nil) == (profileFenceToken == nil) else {
            throw DeviceLegJournalError.invalidState
        }
        guard Self.pin(release, matches: arm.reference) else {
            throw DeviceLegJournalError.invalidState
        }
        guard artifactSource?.descriptorSHA256
                == arm.reference.descriptorSha256
                || artifactSource == nil else {
            throw DeviceLegJournalError.invalidState
        }
        let releaseBytes = try ExactJSONCodec.encode(release)
        guard releaseBytes.count <= Self.maximumReleasePinBytes else {
            throw DeviceLegJournalError.storageLimit
        }
        let file = file
        let root = root
        let releasePinRoot = releasePinRoot
        let releasePinDirectory = releasePinDirectory
        let releasePinBudgetBytes = releasePinBudgetBytes
        let releasePinCountLimit = releasePinCountLimit
        let revocationFile = revocationFile
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            // Another customer instance may have removed this still-empty
            // directory as an orphan before this journal's first admission.
            // Recreate it inside the root transaction before cleanup/write.
            try FileManager.default.createDirectory(
                at: releasePinDirectory,
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: revocationFile.path) else {
                return nil
            }
            var state = try Self.load(file)
            if let stateArmReceipt,
               state.stateArmReceipts?.contains(stateArmReceipt) == true {
                return nil
            }
            try Self.removeUnreferencedReleasePins(
                from: releasePinDirectory,
                state: state
            )
            try Self.removeGlobalOrphanReleasePins(
                from: releasePinRoot,
                journalRoot: root,
                excludingCustomerDirectory: releasePinDirectory
            )
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
                        guard let window = reentry.windowSeconds, window > 0 else { throw DeviceLegJournalError.invalidState }
                        if at.timeIntervalSince(last) < Double(window) { return nil }
                    case .everyTime: break
                    }
                }
                journeyId = UUID.v7().uuidString.lowercased()
                generation = 0
            case .continuation:
                guard let boundId = arm.binding.journeyId, let boundGeneration = arm.binding.generation else {
                    throw DeviceLegJournalError.invalidState
                }
                journeyId = boundId
                generation = boundGeneration
                if previous?.journeyId == journeyId, let previous, previous.generation >= generation { return nil }
            }
            let runId = "\(journeyId):\(generation)"
            guard state.runs[runId] == nil else { return nil }
            guard state.runs.count < 1024 else { throw DeviceLegJournalError.storageLimit }
            let pinFile = try Self.releasePinFile(
                descriptorSHA256: arm.reference.descriptorSha256,
                directory: releasePinDirectory
            )
            let pinExisted = FileManager.default.fileExists(
                atPath: pinFile.path
            )
            let inventory = try Self.releasePinInventory(
                in: releasePinRoot
            )
            guard inventory.count <= releasePinCountLimit,
                  inventory.totalBytes <= releasePinBudgetBytes else {
                throw DeviceLegJournalError.storageLimit
            }
            var createdPinFiles: [URL] = []
            func removeCreatedPinFiles() {
                for file in createdPinFiles {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            var projectedPinBytes = inventory.totalBytes
            if pinExisted {
                guard try Self.loadReleasePinBytes(pinFile) == releaseBytes else {
                    throw DeviceLegJournalError.invalidState
                }
            } else {
                let (nextBytes, overflowed) = projectedPinBytes
                    .addingReportingOverflow(releaseBytes.count)
                guard inventory.count < releasePinCountLimit,
                      !overflowed,
                      nextBytes <= releasePinBudgetBytes else {
                    throw DeviceLegJournalError.storageLimit
                }
                try releaseBytes.write(
                    to: pinFile,
                    options: [
                        .atomic,
                        .completeFileProtectionUntilFirstUserAuthentication,
                    ]
                )
                createdPinFiles.append(pinFile)
                projectedPinBytes = nextBytes
            }
            let inheritedArtifactSHA256s = state.runs.values.first(where: {
                $0.reference.descriptorSha256
                    == arm.reference.descriptorSha256
            })?.artifactSHA256s ?? []
            let artifactSHA256s: [String]
            do {
                if let artifactSource {
                    artifactSHA256s = try Self.pinReleaseArtifacts(
                        artifactSource,
                        in: releasePinDirectory,
                        projectedBytes: &projectedPinBytes,
                        byteLimit: releasePinBudgetBytes,
                        createdFiles: &createdPinFiles
                    )
                } else {
                    artifactSHA256s = inheritedArtifactSHA256s
                }
            } catch {
                removeCreatedPinFiles()
                throw error
            }
            let run = DeviceLegRun(
                journeyId: journeyId,
                generation: generation,
                reference: arm.reference,
                artifactSHA256s: artifactSHA256s,
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
                var receipts = state.stateArmReceipts ?? []
                guard receipts.insert(stateArmReceipt).inserted else {
                    removeCreatedPinFiles()
                    return nil
                }
                state.stateArmReceipts = receipts
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
                        removeCreatedPinFiles()
                        return nil
                    }
                } else {
                    try beforePersist?()
                    try Self.persist(state, to: file)
                    onAdmitted()
                }
                return run
            } catch {
                removeCreatedPinFiles()
                throw error
            }
        }
    }

    func runs() async throws -> [DeviceLegRun] {
        try await read { $0.runs.values.sorted { $0.startedEventId < $1.startedEventId } }
    }

    func releasePin(
        descriptorSHA256: String
    ) async throws -> DeviceLegReleaseProfileEntry? {
        let file = file
        let releasePinDirectory = releasePinDirectory
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
            let pinFile = try Self.releasePinFile(
                descriptorSHA256: descriptorSHA256,
                directory: releasePinDirectory
            )
            guard FileManager.default.fileExists(atPath: pinFile.path) else {
                return nil
            }
            return try ExactJSONCodec.decode(
                DeviceLegReleaseProfileEntry.self,
                from: Self.loadReleasePinBytes(pinFile)
            )
        }
    }

    func pinnedArtifacts(
        forRunId runId: String
    ) async throws -> DeviceLegPinnedReleaseArtifacts? {
        let file = file
        let releasePinDirectory = releasePinDirectory
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            let state = try Self.load(file)
            guard let run = state.runs[runId] else { return nil }
            var objectURLsBySHA256: [String: URL] = [:]
            for sha256 in run.artifactSHA256s {
                let artifactFile = try Self.artifactPinFile(
                    sha256: sha256,
                    directory: releasePinDirectory
                )
                guard FileManager.default.fileExists(
                    atPath: artifactFile.path
                ) else {
                    throw DeviceLegJournalError.invalidState
                }
                objectURLsBySHA256[sha256] = artifactFile
            }
            return DeviceLegPinnedReleaseArtifacts(
                objectURLsBySHA256: objectURLsBySHA256
            )
        }
    }

    func checkmark(experienceId: String) async throws -> DeviceLegCheckmark? {
        try await read { $0.checklist[experienceId] }
    }

    func retainStateArmReceipts(
        _ allowed: Set<DeviceLegStateArmReceipt>
    ) async throws {
        try await update { state in
            state.stateArmReceipts = Set(
                (state.stateArmReceipts ?? []).filter(allowed.contains)
            )
        }
    }

    /// Reopens one state latch without disturbing receipts for other entry
    /// kinds. The filesystem transaction keeps multiple SDK instances from
    /// starting the same arm when they observe the latch transition together.
    func clearStateArmReceipts(
        entryKind: DeviceLegEntryCondition.Kind
    ) async throws {
        try await update { state in
            state.stateArmReceipts = Set(
                (state.stateArmReceipts ?? []).filter {
                    $0.entryKind != entryKind
                }
            )
        }
    }

    /// Keep checkmarks while an experience is delivered, then for its authored
    /// reentry window. Older checkmarks without retention metadata remain
    /// conservative until the coordinated hard cut discards them.
    func retainCheckmarks(
        liveExperiences: [String: DeviceLeg.Reentry],
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
                guard let reentry = checkmark.reentry,
                      let lastSeenLiveAt = checkmark.lastSeenLiveAt else {
                    continue
                }
                switch reentry.type {
                case .oncePerWindow:
                    guard let window = reentry.windowSeconds, window > 0 else {
                        state.checklist.removeValue(forKey: experienceId)
                        continue
                    }
                    if at.timeIntervalSince(lastSeenLiveAt) >= Double(window) {
                        state.checklist.removeValue(forKey: experienceId)
                    }
                case .oneTime, .everyTime:
                    state.checklist.removeValue(forKey: experienceId)
                }
            }
        }
    }

    func recordResponses(_ id: String, values: ExactJSONObject<ExperienceReleaseJSONValue>) async throws {
        try await update { state in
            guard var run = state.runs[id], run.completion == nil else { throw DeviceLegJournalError.invalidState }
            let responses = run.context.responses.merging(values) { _, new in new }
            run.context = .init(event: run.context.event, responses: responses)
            state.runs[id] = run
        }
    }

    @discardableResult
    func stagePresentationPublication(
        _ id: String,
        expectedStepId: String,
        expectedCheckpoint: DeviceLegControlExecutor.Checkpoint?,
        publication: DeviceLegRun.PendingPresentationPublication,
        admission: DeviceLegCommitAdmission
    ) async throws -> Bool {
        let expectedPark = expectedCheckpoint.map {
            DeviceLegRun.Park(
                wakeAt: Self.date($0.wakeAtMillis),
                anchorAt: Self.date($0.anchorAtMillis)
            )
        }
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id],
                  run.startedQueued,
                  run.completion == nil,
                  run.stepId == expectedStepId,
                  run.park == expectedPark else {
                throw DeviceLegJournalError.invalidState
            }
            if let pending = run.pendingPresentationPublication {
                guard pending == publication else {
                    throw DeviceLegJournalError.invalidState
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
        admission: DeviceLegCommitAdmission
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id], run.completion == nil else {
                throw DeviceLegJournalError.invalidState
            }
            guard let pending = run.pendingPresentationPublication else {
                return
            }
            guard pending.invocationId == invocationId else {
                throw DeviceLegJournalError.invalidState
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
        context: ArmedDeviceLeg.Context,
        checkpoint: DeviceLegControlExecutor.Checkpoint? = nil,
        experimentExposure: DeviceLegRun.ExperimentExposure? = nil,
        clearingPresentationPublication invocationId: String? = nil,
        admission: DeviceLegCommitAdmission? = nil
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id], run.startedQueued, run.completion == nil else {
                throw DeviceLegJournalError.invalidState
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
                    throw DeviceLegJournalError.invalidState
                }
                run.pendingPresentationPublication = nil
            }
            run.park = checkpoint.map {
                .init(wakeAt: Self.date($0.wakeAtMillis), anchorAt: Self.date($0.anchorAtMillis))
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
    func markExperimentExposuresShown(
        _ id: String,
        at: Date,
        admission: DeviceLegCommitAdmission
    ) async throws -> Bool {
        try await updateIfCurrent(admission) { state in
            guard var run = state.runs[id], run.startedQueued,
                  run.completion == nil else {
                throw DeviceLegJournalError.invalidState
            }
            for index in run.experimentExposures.indices
            where run.experimentExposures[index].shownAt == nil
                    && !run.experimentExposures[index].queued {
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
                throw DeviceLegJournalError.invalidState
            }
            run.experimentExposures[index].queued = true
            state.runs[id] = run
        }
    }

    func park(_ id: String, stepId: String, until: Date?) async throws {
        try await update { state in
            guard var run = state.runs[id], run.startedQueued, run.completion == nil else {
                throw DeviceLegJournalError.invalidState
            }
            run.stepId = stepId
            run.park = .init(wakeAt: until)
            state.runs[id] = run
        }
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
                throw DeviceLegJournalError.invalidState
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
    func recover(at: Date) async throws -> [DeviceLegRun] {
        let root = root
        let file = file
        let releasePinDirectory = releasePinDirectory
        let revocationFile = revocationFile
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveRootAccess(
            to: root,
            lockScope: lockScope
        ) {
            try FileManager.default.createDirectory(
                at: releasePinDirectory,
                withIntermediateDirectories: true
            )
            var state = try Self.load(file)
            let revoked = FileManager.default.fileExists(
                atPath: revocationFile.path
            )
            var pinsByDigest: [String: DeviceLegReleaseProfileEntry] = [:]
            var invalidPinDigests: Set<String> = []
            for (id, var run) in state.runs where run.completion == nil {
                let digest = run.reference.descriptorSha256
                let pin: DeviceLegReleaseProfileEntry?
                if invalidPinDigests.contains(digest) {
                    pin = nil
                } else if let cached = pinsByDigest[digest] {
                    pin = cached
                } else if let loaded = try? Self.loadReleasePin(
                    descriptorSHA256: digest,
                    directory: releasePinDirectory
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
                    Self.finish(
                        &run,
                        outcome: "abandoned",
                        at: at,
                        eventOutputs: eventOutputs,
                        responseOutputs: run.context.responses
                    )
                    state.runs[id] = run
                }
            }
            try beforePersist?()
            try Self.persist(state, to: file)
            try Self.removeUnreferencedReleasePins(
                from: releasePinDirectory,
                state: state
            )
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
        profileFence: DeviceLegProfileFence,
        profileFenceToken: DeviceLegProfileFenceToken
    ) async throws -> DeviceLegRun? {
        let file = file
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(
            to: file,
            lockScope: lockScope
        ) {
            var state = try Self.load(file)
            guard var run = state.runs[id], run.startedQueued, run.park != nil, run.completion == nil else {
                throw DeviceLegJournalError.invalidState
            }
            run.park = nil
            state.runs[id] = run
            guard try profileFence.performIfCurrent(
                profileFenceToken,
                { () -> Void in
                    try beforePersist?()
                    try Self.persist(state, to: file)
                }
            ) != nil else { return nil }
            return run
        }
    }

    @discardableResult
    func complete(
        _ id: String,
        outcome: String,
        at: Date,
        eventOutputs: ExactJSONObject<ExperienceReleaseJSONValue> = [:],
        responseOutputs: ExactJSONObject<ExperienceReleaseJSONValue> = [:],
        admission: DeviceLegCommitAdmission? = nil
    ) async throws -> Bool {
        let mutation: @Sendable (inout Snapshot) throws -> Void = { state in
            guard var run = state.runs[id] else { throw DeviceLegJournalError.invalidState }
            // A retry cannot rewrite the outcome, outputs, or occurrence time.
            guard run.completion == nil else { return }
            guard !outcome.isEmpty, outcome.utf16.count <= 256 else { throw DeviceLegJournalError.invalidState }
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

    func markStartedQueued(_ run: DeviceLegRun) async throws {
        try await update { state in
            guard var current = state.runs[run.id], current.startedEventId == run.startedEventId else { return }
            current.startedQueued = true
            state.runs[run.id] = current
        }
    }

    func markCompletionQueued(_ run: DeviceLegRun) async throws {
        try await update(cleanupReleasePins: true) { state in
            guard let current = state.runs[run.id], current.completedEventId == run.completedEventId else { return }
            guard current.startedQueued, let completion = current.completion else { throw DeviceLegJournalError.invalidState }
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
        _ release: DeviceLegReleaseProfileEntry,
        matches reference: ArmedDeviceLeg.Reference
    ) -> Bool {
        release.envelope.descriptorSha256 == reference.descriptorSha256
            && release.locator.experienceId == reference.experienceId
            && release.locator.experienceVersionId == reference.versionId
            && release.locator.legId == reference.legId
    }

    private static func finish(
        _ run: inout DeviceLegRun,
        outcome: String,
        at: Date,
        eventOutputs: ExactJSONObject<ExperienceReleaseJSONValue>,
        responseOutputs: ExactJSONObject<ExperienceReleaseJSONValue>
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
        let releasePinDirectory = releasePinDirectory
        let beforePersist = beforePersist
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(to: file, lockScope: lockScope) {
            var state = try Self.load(file)
            let value = try operation(&state)
            try beforePersist?()
            try Self.persist(state, to: file)
            if cleanupReleasePins {
                try Self.removeUnreferencedReleasePins(
                    from: releasePinDirectory,
                    state: state
                )
            }
            return value
        }
    }

    private func updateIfCurrent<Value: Sendable>(
        _ admission: DeviceLegCommitAdmission,
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
            throw DeviceLegJournalError.storageLimit
        }
        try bytes.write(
            to: file,
            options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ]
        )
    }

    private static func releasePinFile(
        descriptorSHA256: String,
        directory: URL
    ) throws -> URL {
        guard isLowercaseSHA256(descriptorSHA256) else {
            throw DeviceLegJournalError.invalidState
        }
        return directory.appendingPathComponent(
            "\(descriptorSHA256).json",
            isDirectory: false
        )
    }

    private static func artifactPinFile(
        sha256: String,
        directory: URL
    ) throws -> URL {
        guard isLowercaseSHA256(sha256) else {
            throw DeviceLegJournalError.invalidState
        }
        return directory.appendingPathComponent(
            "\(sha256).artifact",
            isDirectory: false
        )
    }

    private static func pinReleaseArtifacts(
        _ source: DeviceLegReleaseArtifactSource,
        in directory: URL,
        projectedBytes: inout Int,
        byteLimit: Int,
        createdFiles: inout [URL]
    ) throws -> [String] {
        guard source.objects.count
                <= ExperienceReleaseDescriptorLimits.assetCount
                    + ExperienceReleaseDescriptorLimits.screenCount
                    + 1,
              Set(source.objects.map(\.sha256)).count == source.objects.count else {
            throw DeviceLegJournalError.invalidState
        }
        var declaredBytes = 0
        for object in source.objects {
            guard isLowercaseSHA256(object.sha256),
                  object.sizeBytes > 0,
                  object.sizeBytes
                    <= ExperienceReleaseDescriptorLimits.rivArtifactBytes else {
                throw DeviceLegJournalError.invalidState
            }
            let (nextBytes, overflowed) = declaredBytes.addingReportingOverflow(
                object.sizeBytes
            )
            guard !overflowed,
                  nextBytes
                    <= ExperienceReleaseDescriptorLimits.artifactAggregateBytes else {
                throw DeviceLegJournalError.storageLimit
            }
            declaredBytes = nextBytes
        }
        var pinned: [String] = []
        pinned.reserveCapacity(source.objects.count)
        for object in source.objects.sorted(by: { $0.sha256 < $1.sha256 }) {
            let destination = try artifactPinFile(
                sha256: object.sha256,
                directory: directory
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                let retained = try BoundedFileIO.read(
                    at: destination,
                    maximumBytes: object.sizeBytes
                )
                guard retained.digest.byteCount == object.sizeBytes,
                      retained.digest.sha256 == object.sha256 else {
                    throw DeviceLegJournalError.invalidState
                }
                pinned.append(object.sha256)
                continue
            }

            let sourceFile = source.cacheRoot.appendingPathComponent(
                object.sha256,
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: sourceFile.path) else {
                if object.required {
                    throw DeviceLegJournalError.invalidState
                }
                continue
            }
            let acquired = try BoundedFileIO.read(
                at: sourceFile,
                maximumBytes: object.sizeBytes
            )
            guard acquired.digest.byteCount == object.sizeBytes,
                  acquired.digest.sha256 == object.sha256 else {
                throw DeviceLegJournalError.invalidState
            }
            let (nextBytes, overflowed) = projectedBytes
                .addingReportingOverflow(acquired.data.count)
            guard !overflowed, nextBytes <= byteLimit else {
                throw DeviceLegJournalError.storageLimit
            }
            try acquired.data.write(
                to: destination,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            createdFiles.append(destination)
            projectedBytes = nextBytes
            pinned.append(object.sha256)
        }
        return pinned
    }

    private static func loadReleasePinBytes(_ file: URL) throws -> Data {
        try BoundedFileIO.read(
            at: file,
            maximumBytes: maximumReleasePinBytes
        ).data
    }

    private static func loadReleasePin(
        descriptorSHA256: String,
        directory: URL
    ) throws -> DeviceLegReleaseProfileEntry? {
        let file = try releasePinFile(
            descriptorSHA256: descriptorSHA256,
            directory: directory
        )
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return try ExactJSONCodec.decode(
            DeviceLegReleaseProfileEntry.self,
            from: loadReleasePinBytes(file)
        )
    }

    private static func removeUnreferencedReleasePins(
        from directory: URL,
        state: Snapshot
    ) throws {
        let fileManager = FileManager.default
        let referenced = Set(state.runs.values.map {
            $0.reference.descriptorSha256
        })
        let referencedArtifacts = Set(
            state.runs.values.flatMap(\.artifactSHA256s)
        )
        for file in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let sha256 = file.deletingPathExtension().lastPathComponent
            let isReferencedDescriptor = file.pathExtension == "json"
                && (try? releasePinFile(
                    descriptorSHA256: sha256,
                    directory: directory
                )) != nil
                && referenced.contains(sha256)
            let isReferencedArtifact = file.pathExtension == "artifact"
                && (try? artifactPinFile(
                    sha256: sha256,
                    directory: directory
                )) != nil
                && referencedArtifacts.contains(sha256)
            if !isReferencedDescriptor && !isReferencedArtifact {
                try fileManager.removeItem(at: file)
            }
        }
    }

    private static func removeGlobalOrphanReleasePins(
        from releasePinRoot: URL,
        journalRoot: URL,
        excludingCustomerDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let excluded = excludingCustomerDirectory.lastPathComponent
        for customerDirectory in try fileManager.contentsOfDirectory(
            at: releasePinRoot,
            includingPropertiesForKeys: nil
        ) {
            let customerDigest = customerDirectory.lastPathComponent
            let attributes = try fileManager.attributesOfItem(
                atPath: customerDirectory.path
            )
            guard isLowercaseSHA256(customerDigest),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                try fileManager.removeItem(at: customerDirectory)
                continue
            }
            guard customerDigest != excluded else { continue }
            let journalFile = journalRoot.appendingPathComponent(
                "\(customerDigest).json",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: journalFile.path) else {
                try fileManager.removeItem(at: customerDirectory)
                continue
            }
            guard let state = try? load(journalFile) else {
                // A transiently unreadable journal may still be recoverable;
                // count its pins against the global budget without deleting
                // its only retained execution authority.
                continue
            }
            try removeUnreferencedReleasePins(
                from: customerDirectory,
                state: state
            )
        }
    }

    private static func releasePinInventory(
        in releasePinRoot: URL
    ) throws -> (count: Int, totalBytes: Int) {
        let fileManager = FileManager.default
        var count = 0
        var totalBytes = 0
        for customerDirectory in try fileManager.contentsOfDirectory(
            at: releasePinRoot,
            includingPropertiesForKeys: nil
        ) {
            let customerDigest = customerDirectory.lastPathComponent
            let directoryAttributes = try fileManager.attributesOfItem(
                atPath: customerDirectory.path
            )
            guard isLowercaseSHA256(customerDigest),
                  directoryAttributes[.type] as? FileAttributeType
                    == .typeDirectory else {
                throw DeviceLegJournalError.invalidState
            }
            for file in try fileManager.contentsOfDirectory(
                at: customerDirectory,
                includingPropertiesForKeys: nil
            ) {
                let sha256 = file.deletingPathExtension()
                    .lastPathComponent
                let isDescriptor = file.pathExtension == "json"
                    && (try? releasePinFile(
                        descriptorSHA256: sha256,
                        directory: customerDirectory
                    )) != nil
                let isArtifact = file.pathExtension == "artifact"
                    && (try? artifactPinFile(
                        sha256: sha256,
                        directory: customerDirectory
                    )) != nil
                guard isDescriptor || isArtifact else {
                    throw DeviceLegJournalError.invalidState
                }
                let bytes = try regularFileSize(
                    file,
                    maximumBytes: isDescriptor
                        ? maximumReleasePinBytes
                        : ExperienceReleaseDescriptorLimits.rivArtifactBytes
                )
                let (nextTotal, overflowed) = totalBytes
                    .addingReportingOverflow(bytes)
                guard !overflowed else {
                    throw DeviceLegJournalError.storageLimit
                }
                totalBytes = nextTotal
                if isDescriptor { count += 1 }
            }
        }
        return (count, totalBytes)
    }

    private static func regularFileSize(
        _ file: URL,
        maximumBytes: Int
    ) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw DeviceLegJournalError.invalidState
        }
        let value = size.int64Value
        guard value >= 0,
              value <= Int64(maximumBytes) else {
            throw DeviceLegJournalError.storageLimit
        }
        return Int(value)
    }

    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }

    private static func load(_ file: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let bytes = try BoundedFileIO.read(at: file, maximumBytes: maximumBytes).data
        let state = try ExactJSONCodec.decode(Snapshot.self, from: bytes)
        guard state.schemaVersion == "nuxie.device-leg-journal.v1" else { throw DeviceLegJournalError.unsupportedVersion }
        return state
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

extension DeviceLegRun: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case journeyId
        case generation
        case reference
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
        reference = try container.decode(ArmedDeviceLeg.Reference.self, forKey: .reference)
        artifactSHA256s = try container.decodeIfPresent(
            [String].self,
            forKey: .artifactSHA256s
        ) ?? []
        guard artifactSHA256s == artifactSHA256s.sorted(),
              Set(artifactSHA256s).count == artifactSHA256s.count,
              artifactSHA256s.allSatisfy(DeviceLegRunJournal.isLowercaseSHA256) else {
            throw DeviceLegJournalError.invalidState
        }
        reentry = try container.decodeIfPresent(
            DeviceLeg.Reentry.self,
            forKey: .reentry
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        isEnrollment = try container.decode(Bool.self, forKey: .isEnrollment)
        startedEventId = try container.decode(String.self, forKey: .startedEventId)
        completedEventId = try container.decode(String.self, forKey: .completedEventId)
        startedQueued = try container.decodeIfPresent(Bool.self, forKey: .startedQueued) ?? false
        stepId = try container.decode(String.self, forKey: .stepId)
        park = try container.decodeIfPresent(Park.self, forKey: .park)
        context = try container.decode(ArmedDeviceLeg.Context.self, forKey: .context)
        outputs = try container.decodeIfPresent(
            ArmedDeviceLeg.Context.self,
            forKey: .outputs
        ) ?? .init(event: [:], responses: [:])
        effectReceipts = try container.decodeIfPresent(
            [String: String].self,
            forKey: .effectReceipts
        ) ?? [:]
        experimentExposures = try container.decodeIfPresent(
            [ExperimentExposure].self,
            forKey: .experimentExposures
        ) ?? []
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
        try container.encode(artifactSHA256s, forKey: .artifactSHA256s)
        try container.encodeIfPresent(reentry, forKey: .reentry)
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
extension DeviceLegRun.Park: Codable, Equatable, Sendable {}
extension DeviceLegRun.Completion: Codable, Sendable {}
extension DeviceLegCheckmark: Codable, Sendable {
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
            reentry: try container.decodeIfPresent(
                DeviceLeg.Reentry.self,
                forKey: .reentry
            ),
            lastSeenLiveAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastSeenLiveAt
            )
        )
    }
}
extension DeviceLegJournalError: Error {}
extension DeviceLegRunJournal: Sendable {}
extension DeviceLegRunJournal.Snapshot: Codable {}
