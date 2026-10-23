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
        in journal: CustomerJourneyStore,
        at date: Date,
        admission: JourneyCommitAdmission
    ) async {
        let mark = PendingMark(
            runId: runId,
            screenId: screenId,
            shownAt: date,
            admission: admission
        )
        let observedGeneration = generation
        retainPendingMark(mark, in: journal)
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
            guard observedGeneration == generation else { return }
            LogWarning(
                "JourneyExperimentExposureCoordinator: failed to queue shown exposure: \(error)"
            )
            retainPendingMark(mark, in: journal)
            await scheduleRetry(for: journal)
        }
    }

    @discardableResult
    func flushPending(in journal: CustomerJourneyStore, admission: JourneyCommitAdmission? = nil) async throws -> Bool {
        let marks = pendingMarks[journal.distinctId].map { Array($0.values) } ?? []
        for mark in marks {
            guard try await journal.markExperimentExposuresShown(mark.runId, screenId: mark.screenId, at: mark.shownAt, admission: mark.admission) else { return false }
            removePendingMark(mark, from: journal)
        }
        return true
    }

    func cancelPendingPublication() {
        generation &+= 1
        pendingMarks.removeAll()
    }

    private func scheduleRetry(for journal: CustomerJourneyStore) async {
        let generation = generation
        await events.enqueueJourneyWork(.init(key: .init(distinctId: journal.distinctId, id: "exposure-publication"),
            operation: { [weak self] in
                guard let self else { return .done }
                return await self.retryOnce(in: journal, generation: generation)
            }))
    }

    private func retryOnce(
        in journal: CustomerJourneyStore, generation: UInt64
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
        if !markFailed && pendingMarks[journalKey]?.isEmpty != false { return .done }
        return .failed
    }

    private func retainPendingMark(
        _ mark: PendingMark,
        in journal: CustomerJourneyStore
    ) {
        pendingMarks[journal.distinctId, default: [:]][
            pendingMarkKey(mark)
        ] = mark
    }

    private func removePendingMark(
        _ mark: PendingMark,
        from journal: CustomerJourneyStore
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
