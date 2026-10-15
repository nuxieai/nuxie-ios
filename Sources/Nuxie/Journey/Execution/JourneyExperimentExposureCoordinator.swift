import Foundation

/// Owns exposure publication and its retry lifecycle independently of leg
/// execution. Committed selector decisions are publishable without presentation.
actor JourneyExperimentExposureCoordinator {
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

    @discardableResult
    func flushPending(
        in journal: JourneyRunJournal,
        admission: JourneyCommitAdmission? = nil
    ) async throws -> Bool {
        do {
            let settled = try await JourneyExperimentExposureReporter(
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

    private func scheduleRetry(for journal: JourneyRunJournal) {
        let key = journal.distinctId
        guard retryTasks[key] == nil else { return }
        retryTasks[key] = Task { [weak self] in
            await self?.retry(in: journal, key: key)
        }
    }

    private func retry(
        in journal: JourneyRunJournal,
        key: String
    ) async {
        defer { retryTasks.removeValue(forKey: key) }
        await retryLoop.run { [weak self] in
            guard let self else { return .finished }
            return await self.retryOnce(in: journal)
        }
    }

    private func retryOnce(
        in journal: JourneyRunJournal
    ) async -> CancellationAwareExponentialRetryLoop.IterationResult {
        do {
            let settled = try await JourneyExperimentExposureReporter(
                journal: journal,
                events: events
            ).flushPending()
            try await JourneyReporter(
                journal: journal,
                events: events
            ).flushPending()
            if settled {
                _ = try await journal.finalizeRevocation()
                return .finished
            }
        } catch {
            LogWarning(
                "JourneyExperimentExposureCoordinator: exposure retry remains pending: \(error)"
            )
        }
        return .pending
    }

}
