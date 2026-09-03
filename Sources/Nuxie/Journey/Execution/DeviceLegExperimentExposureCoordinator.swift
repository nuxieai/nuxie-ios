import Foundation

/// Owns exposure publication and its retry lifecycle independently of leg
/// execution. A selected experiment becomes publishable only after the
/// presentation layer proves that its screen was visible.
actor DeviceLegExperimentExposureCoordinator {
    private struct PendingMark: Sendable {
        let runId: String
        let screenId: String
        let shownAt: Date
        let admission: DeviceLegCommitAdmission
    }

    private struct PendingMarkKey: Hashable, Sendable {
        let runId: String
        let screenId: String
    }

    private let events: any RoutedStableSystemEventCapturing
    private let retryLoop = CancellationAwareExponentialRetryLoop(
        initialDelayNanoseconds: 250_000_000,
        maximumDelayNanoseconds: 2_000_000_000
    )
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var pendingMarks: [String: [PendingMarkKey: PendingMark]] = [:]

    init(events: any RoutedStableSystemEventCapturing) {
        self.events = events
    }

    deinit {
        retryTasks.values.forEach { $0.cancel() }
    }

    func markShown(
        forRunId runId: String,
        screenId: String,
        in journal: DeviceLegRunJournal,
        at date: Date,
        admission: DeviceLegCommitAdmission
    ) async {
        let mark = PendingMark(
            runId: runId,
            screenId: screenId,
            shownAt: date,
            admission: admission
        )
        do {
            guard try await journal.markExperimentExposuresShown(
                runId,
                screenId: screenId,
                at: date,
                admission: admission
            ) else { return }
            removePendingMark(mark, from: journal)
            try await flushPending(in: journal, admission: admission)
        } catch {
            LogWarning(
                "DeviceLegExperimentExposureCoordinator: failed to queue shown exposure: \(error)"
            )
            retainPendingMark(mark, in: journal)
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
        pendingMarks.removeAll()
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
        var markFailed = false
        let journalKey = journal.distinctId
        let marks = pendingMarks[journalKey].map { Array($0.values) } ?? []
        for mark in marks {
            do {
                _ = try await journal.markExperimentExposuresShown(
                    mark.runId,
                    screenId: mark.screenId,
                    at: mark.shownAt,
                    admission: mark.admission
                )
                removePendingMark(mark, from: journal)
            } catch {
                markFailed = true
                LogWarning(
                    "DeviceLegExperimentExposureCoordinator: shown exposure mark remains pending: \(error)"
                )
            }
        }
        do {
            let settled = try await DeviceLegExperimentExposureReporter(
                journal: journal,
                events: events
            ).flushPending()
            try await DeviceLegReporter(
                journal: journal,
                events: events
            ).flushPending()
            if settled && !markFailed
                    && pendingMarks[journalKey]?.isEmpty != false {
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

    private func retainPendingMark(
        _ mark: PendingMark,
        in journal: DeviceLegRunJournal
    ) {
        pendingMarks[journal.distinctId, default: [:]][
            pendingMarkKey(mark)
        ] = mark
    }

    private func removePendingMark(
        _ mark: PendingMark,
        from journal: DeviceLegRunJournal
    ) {
        let journalKey = journal.distinctId
        pendingMarks[journalKey]?.removeValue(forKey: pendingMarkKey(mark))
        if pendingMarks[journalKey]?.isEmpty == true {
            pendingMarks.removeValue(forKey: journalKey)
        }
    }

    private func pendingMarkKey(_ mark: PendingMark) -> PendingMarkKey {
        PendingMarkKey(runId: mark.runId, screenId: mark.screenId)
    }
}
