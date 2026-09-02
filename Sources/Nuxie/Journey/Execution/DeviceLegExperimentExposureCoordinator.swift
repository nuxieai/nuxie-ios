import Foundation

/// Owns exposure publication and its retry lifecycle independently of leg
/// execution. A selected experiment becomes publishable only after the
/// presentation layer proves that its screen was visible.
actor DeviceLegExperimentExposureCoordinator {
    private let events: any RoutedStableSystemEventCapturing
    private let retryLoop = CancellationAwareExponentialRetryLoop(
        initialDelayNanoseconds: 250_000_000,
        maximumDelayNanoseconds: 2_000_000_000
    )
    private var retryTasks: [String: Task<Void, Never>] = [:]

    init(events: any RoutedStableSystemEventCapturing) {
        self.events = events
    }

    deinit {
        retryTasks.values.forEach { $0.cancel() }
    }

    func markShown(
        forRunId runId: String,
        in journal: DeviceLegRunJournal,
        at date: Date,
        admission: DeviceLegCommitAdmission
    ) async {
        let runs: [DeviceLegRun]
        do {
            runs = try await journal.runs()
        } catch {
            LogWarning(
                "DeviceLegExperimentExposureCoordinator: failed to read pending exposure: \(error)"
            )
            return
        }
        guard let run = runs.first(where: { $0.id == runId }),
              run.experimentExposures.contains(where: {
                $0.shownAt == nil && !$0.queued
              }) else { return }
        do {
            guard try await journal.markExperimentExposuresShown(
                runId,
                at: date,
                admission: admission
            ) else { return }
            try await flushPending(in: journal, admission: admission)
        } catch {
            LogWarning(
                "DeviceLegExperimentExposureCoordinator: failed to queue shown exposure: \(error)"
            )
            scheduleRetry(for: journal)
        }
    }

    @discardableResult
    func flushPending(
        in journal: DeviceLegRunJournal,
        admission: DeviceLegCommitAdmission? = nil
    ) async throws -> Bool {
        do {
            let settled = try await DeviceLegExperimentExposureReporter(
                journal: journal,
                events: events
            ).flushPending(admission: admission)
            if !settled {
                scheduleRetry(for: journal)
            }
            return settled
        } catch {
            scheduleRetry(for: journal)
            throw error
        }
    }

    func cancelAndAwaitRetries() async {
        let retries = Array(retryTasks.values)
        retries.forEach { $0.cancel() }
        for retry in retries {
            await retry.value
        }
        retryTasks.removeAll()
    }

    private func scheduleRetry(for journal: DeviceLegRunJournal) {
        let key = journal.distinctId
        guard retryTasks[key] == nil else { return }
        retryTasks[key] = Task { [weak self] in
            await self?.retry(in: journal, key: key)
        }
    }

    private func retry(
        in journal: DeviceLegRunJournal,
        key: String
    ) async {
        defer { retryTasks.removeValue(forKey: key) }
        await retryLoop.run { [weak self] in
            guard let self else { return .finished }
            return await self.retryOnce(in: journal)
        }
    }

    private func retryOnce(
        in journal: DeviceLegRunJournal
    ) async -> CancellationAwareExponentialRetryLoop.IterationResult {
        do {
            let settled = try await DeviceLegExperimentExposureReporter(
                journal: journal,
                events: events
            ).flushPending()
            try await DeviceLegReporter(
                journal: journal,
                events: events
            ).flushPending()
            if settled {
                _ = try await journal.finalizeRevocation()
                return .finished
            }
        } catch {
            LogWarning(
                "DeviceLegExperimentExposureCoordinator: exposure retry remains pending: \(error)"
            )
        }
        return .pending
    }
}
