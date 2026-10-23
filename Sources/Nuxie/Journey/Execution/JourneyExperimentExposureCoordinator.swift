import Foundation

/// Records exposure publication work in the ordered customer queue. A
/// selected experiment becomes publishable only after the presentation
/// layer proves that its screen was visible.
actor JourneyExperimentExposureCoordinator {
    private struct PendingMark: Sendable {
        let runId: String
        let screenId: String
        let shownAt: Date
        let admission: JourneyCommitAdmission
    }

    private struct PendingMarkKey: Hashable, Sendable {
        let runId: String
        let screenId: String
    }

    private let events: any EventLogProtocol
    private var generation: UInt64 = 0
    private var pendingMarks: [String: [PendingMarkKey: PendingMark]] = [:]

    init(events: any EventLogProtocol) {
        self.events = events
    }

    func markShown(
        forRunId runId: String,
        screenId: String,
        in journal: JourneyRunJournal,
        at date: Date,
        admission: JourneyCommitAdmission
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
                "JourneyExperimentExposureCoordinator: failed to queue shown exposure: \(error)"
            )
            retainPendingMark(mark, in: journal)
            await scheduleRetry(for: journal)
        }
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
                await scheduleRetry(for: journal)
            }
            return settled
        } catch {
            await scheduleRetry(for: journal)
            throw error
        }
    }

    func cancelPendingPublication() {
        generation &+= 1
        pendingMarks.removeAll()
    }

    private func scheduleRetry(for journal: JourneyRunJournal) async {
        let generation = generation
        await events.enqueueJourneyWork(.init(key: .init(distinctId: journal.distinctId, id: "exposure-publication"),
            operation: { [weak self] in
                guard let self else { return .done }
                return await self.retryOnce(in: journal, generation: generation)
            }))
    }

    private func retryOnce(
        in journal: JourneyRunJournal, generation: UInt64
    ) async -> JourneyQueueResult {
        guard generation == self.generation else { return .done }
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
                    "JourneyExperimentExposureCoordinator: shown exposure mark remains pending: \(error)"
                )
            }
        }
        do {
            let settled = try await JourneyExperimentExposureReporter(
                journal: journal,
                events: events
            ).flushPending()
            try await JourneyReporter(
                journal: journal,
                events: events
            ).flushPending()
            let reportsPending = try await journal.runs().contains { !$0.startedQueued || $0.completion != nil }
            if settled && !markFailed && !reportsPending
                    && pendingMarks[journalKey]?.isEmpty != false {
                _ = try await journal.finalizeRevocation()
                return .done
            }
        } catch {
            LogWarning(
                "JourneyExperimentExposureCoordinator: exposure retry remains pending: \(error)"
            )
        }
        return .failed
    }

    private func retainPendingMark(
        _ mark: PendingMark,
        in journal: JourneyRunJournal
    ) {
        pendingMarks[journal.distinctId, default: [:]][
            pendingMarkKey(mark)
        ] = mark
    }

    private func removePendingMark(
        _ mark: PendingMark,
        from journal: JourneyRunJournal
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
