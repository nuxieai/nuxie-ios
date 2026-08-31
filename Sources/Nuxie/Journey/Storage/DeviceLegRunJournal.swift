import CryptoKit
import Foundation

struct DeviceLegRun {
    struct Park {
        let wakeAt: Date?
    }
    struct Completion {
        let outcome: String
        let at: Date
    }

    let journeyId: String
    let generation: Int
    let reference: ArmedDeviceLeg.Reference
    let startedAt: Date
    let isEnrollment: Bool
    let startedEventId: String
    let completedEventId: String
    var startedQueued = false
    var stepId: String
    var park: Park?
    var context: ArmedDeviceLeg.Context
    var outputs = ArmedDeviceLeg.Context(event: [:], responses: [:])
    var completion: Completion?

    var id: String { "\(journeyId):\(generation)" }
}

struct DeviceLegCheckmark {
    let journeyId: String
    let generation: Int
    let outcome: String
    let completedAt: Date
    /// Reentry counts new journeys, not completion time or continuation legs.
    let lastEnrollmentAt: Date?
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
    }

    let distinctId: String
    private let file: URL
    private let lockScope: CacheFilesystemLockScope
    private static let maximumBytes = 16 * 1024 * 1024

    init(directory: URL, distinctId: String) throws {
        self.distinctId = distinctId
        let root = directory.appendingPathComponent("device-leg-journal-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(distinctId.utf8)).map { String(format: "%02x", $0) }.joined()
        file = root.appendingPathComponent("\(digest).json")
        lockScope = CacheFilesystemLockScope(cacheRootURL: root)
    }

    /// Called only after the arm and its signed release have been admitted.
    /// Persist before running any action, including emitting the started fact.
    func admit(arm: ArmedDeviceLeg, reentry: DeviceLeg.Reentry, entryStepId: String, at: Date) async throws -> DeviceLegRun? {
        try await update { state in
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
            let run = DeviceLegRun(journeyId: journeyId, generation: generation, reference: arm.reference,
                                   startedAt: at, isEnrollment: arm.binding.type == .new,
                                   startedEventId: UUID.v7().uuidString.lowercased(),
                                   completedEventId: UUID.v7().uuidString.lowercased(),
                                   stepId: entryStepId, context: arm.context)
            guard state.runs[run.id] == nil else { return nil }
            guard state.runs.count < 1024 else { throw DeviceLegJournalError.storageLimit }
            state.runs[run.id] = run
            return run
        }
    }

    func runs() async throws -> [DeviceLegRun] {
        try await read { $0.runs.values.sorted { $0.startedEventId < $1.startedEventId } }
    }

    func checkmark(experienceId: String) async throws -> DeviceLegCheckmark? {
        try await read { $0.checklist[experienceId] }
    }

    func recordResponses(_ id: String, values: [String: ExperienceReleaseJSONValue]) async throws {
        try await update { state in
            guard var run = state.runs[id], run.completion == nil else { throw DeviceLegJournalError.invalidState }
            let responses = run.context.responses.merging(values) { _, new in new }
            run.context = .init(event: run.context.event, responses: responses)
            run.outputs = .init(event: run.outputs.event, responses: run.outputs.responses.merging(values) { _, new in new })
            state.runs[id] = run
        }
    }

    func recordEventOutputs(_ id: String, values: [String: ExperienceReleaseJSONValue]) async throws {
        try await update { state in
            guard var run = state.runs[id], run.completion == nil else { throw DeviceLegJournalError.invalidState }
            run.outputs = .init(event: run.outputs.event.merging(values) { _, new in new }, responses: run.outputs.responses)
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

    /// Called once on process launch, before any leg executes. Expired waits
    /// remain parked so the executor can evaluate them against current facts.
    func recover(at: Date) async throws -> [DeviceLegRun] {
        try await update { state in
            for (id, var run) in state.runs where run.park == nil && run.completion == nil {
                run.completion = .init(outcome: "abandoned", at: at)
                state.runs[id] = run
            }
            return state.runs.values.filter { $0.park != nil && $0.completion == nil }
                .sorted { $0.startedEventId < $1.startedEventId }
        }
    }

    /// Consume the only resumable checkpoint before running its continuation.
    /// The caller must first establish that this wait should wake now.
    func resumeParked(_ id: String) async throws -> DeviceLegRun {
        try await update { state in
            guard var run = state.runs[id], run.startedQueued, run.park != nil, run.completion == nil else {
                throw DeviceLegJournalError.invalidState
            }
            run.park = nil
            state.runs[id] = run
            return run
        }
    }

    func complete(_ id: String, outcome: String, at: Date) async throws {
        try await update { state in
            guard var run = state.runs[id] else { throw DeviceLegJournalError.invalidState }
            // A retry cannot rewrite the outcome, outputs, or occurrence time.
            guard run.completion == nil else { return }
            guard !outcome.isEmpty, outcome.utf16.count <= 256 else { throw DeviceLegJournalError.invalidState }
            run.completion = .init(outcome: outcome, at: at)
            state.runs[id] = run
        }
    }

    func markStartedQueued(_ run: DeviceLegRun) async throws {
        try await update { state in
            guard var current = state.runs[run.id], current.startedEventId == run.startedEventId else { return }
            current.startedQueued = true
            state.runs[run.id] = current
        }
    }

    func markCompletionQueued(_ run: DeviceLegRun) async throws {
        try await update { state in
            guard let current = state.runs[run.id], current.completedEventId == run.completedEventId else { return }
            guard current.startedQueued, let completion = current.completion else { throw DeviceLegJournalError.invalidState }
            let experienceId = current.reference.experienceId
            let previous = state.checklist[experienceId]
            let lastEnrollment = [previous?.lastEnrollmentAt, current.isEnrollment ? current.startedAt : nil].compactMap { $0 }.max()
            let newer = previous.flatMap { $0.journeyId == current.journeyId && $0.generation > current.generation ? $0 : nil }
            state.checklist[experienceId] = .init(journeyId: current.journeyId, generation: newer?.generation ?? current.generation,
                                                 outcome: newer?.outcome ?? completion.outcome, completedAt: newer?.completedAt ?? completion.at,
                                                 lastEnrollmentAt: lastEnrollment)
            state.runs.removeValue(forKey: current.id)
        }
    }

    private func read<Value: Sendable>(_ operation: @escaping @Sendable (Snapshot) throws -> Value) async throws -> Value {
        let file = file
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(to: file, lockScope: lockScope) {
            try operation(Self.load(file))
        }
    }

    private func update<Value: Sendable>(_ operation: @escaping @Sendable (inout Snapshot) throws -> Value) async throws -> Value {
        let file = file
        return try await SharedCachePathCoordinator.shared.withExclusiveAccess(to: file, lockScope: lockScope) {
            var state = try Self.load(file)
            let value = try operation(&state)
            let bytes = try JSONEncoder().encode(state)
            guard bytes.count <= Self.maximumBytes else { throw DeviceLegJournalError.storageLimit }
            try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return value
        }
    }

    private static func load(_ file: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        let bytes = try BoundedFileIO.read(at: file, maximumBytes: maximumBytes).data
        let state = try JSONDecoder().decode(Snapshot.self, from: bytes)
        guard state.schemaVersion == "nuxie.device-leg-journal.v1" else { throw DeviceLegJournalError.unsupportedVersion }
        return state
    }
}

extension DeviceLegRun: Codable, Sendable {}
extension DeviceLegRun.Park: Codable, Sendable {}
extension DeviceLegRun.Completion: Codable, Sendable {}
extension DeviceLegCheckmark: Codable, Sendable {}
extension DeviceLegJournalError: Error {}
extension DeviceLegRunJournal: Sendable {}
extension DeviceLegRunJournal.Snapshot: Codable {}
