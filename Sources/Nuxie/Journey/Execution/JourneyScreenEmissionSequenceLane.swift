#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation

/// Orders durable renderer batches for one journey. Admission and effect
/// execution remain in `JourneyService`; this actor owns only replay joining
/// and predecessor sequencing.
actor JourneyScreenEmissionSequenceLane {
    typealias Operation = @Sendable () async -> JourneyScreenEmissionDrainResult
    typealias Rejection = @Sendable () -> JourneyScreenEmissionDrainResult

    private struct Pending: Sendable {
        let batch: ScreenEmissionBatch
        let process: Operation
        let reject: Rejection
        var waiters: [CheckedContinuation<JourneyScreenEmissionDrainResult, Never>]
    }

    private var lastProcessedSequence: UInt64?
    private var initialized = false
    private var pending: [UInt64: Pending] = [:]
    private var processed: [UInt64: (invocationId: String, result: JourneyScreenEmissionDrainResult)] = [:]
    private var active: Pending?
    private var draining = false
    private var drainTask: Task<Void, Never>?
    private var closeReason: JourneyScreenEmissionSkipReason?

    func submit(
        _ batch: ScreenEmissionBatch,
        durableLastProcessedSequence: UInt64?,
        durableResult: JourneyScreenEmissionDrainResult?,
        process: @escaping Operation,
        reject: @escaping Rejection
    ) async -> JourneyScreenEmissionDrainResult {
        if let closeReason {
            return aborted(batch, reason: closeReason)
        }
        if !initialized {
            lastProcessedSequence = durableLastProcessedSequence
            initialized = true
        } else if let durableLastProcessedSequence {
            if let current = lastProcessedSequence {
                lastProcessedSequence = max(current, durableLastProcessedSequence)
            } else {
                lastProcessedSequence = durableLastProcessedSequence
            }
            pump()
        }
        if let previous = batch.previousCommittedBatchSequence,
           previous >= batch.batchSequence {
            return reject()
        }
        if let completed = processed[batch.batchSequence] {
            return completed.invocationId == batch.invocationId
                ? completed.result
                : reject()
        }
        if let durableResult {
            if let current = lastProcessedSequence {
                lastProcessedSequence = max(current, batch.batchSequence)
            } else {
                lastProcessedSequence = batch.batchSequence
            }
            processed[batch.batchSequence] = (
                invocationId: batch.invocationId,
                result: durableResult
            )
            pump()
            return durableResult
        }
        if let lastProcessedSequence,
           batch.batchSequence <= lastProcessedSequence {
            return reject()
        }
        if var current = active, current.batch.batchSequence == batch.batchSequence {
            guard current.batch.invocationId == batch.invocationId else {
                return reject()
            }
            return await withCheckedContinuation { continuation in
                current.waiters.append(continuation)
                active = current
            }
        }

        return await withCheckedContinuation { continuation in
            if var existing = pending[batch.batchSequence] {
                guard existing.batch.invocationId == batch.invocationId else {
                    continuation.resume(returning: reject())
                    return
                }
                existing.waiters.append(continuation)
                pending[batch.batchSequence] = existing
                return
            }
            pending[batch.batchSequence] = Pending(
                batch: batch,
                process: process,
                reject: reject,
                waiters: [continuation]
            )
            pump()
        }
    }

    func close(reason: JourneyScreenEmissionSkipReason) {
        guard closeReason == nil else { return }
        closeReason = reason
        drainTask?.cancel()
        // Do not join here: the external operation may ignore cancellation.
        // Submit waiters are resolved below, and the weak completion callback
        // prevents the abandoned worker from retaining this closed lane.
        drainTask = nil

        let unresolved = [active].compactMap { $0 } + Array(pending.values)
        active = nil
        pending.removeAll()
        draining = false
        for submission in unresolved {
            let result = aborted(submission.batch, reason: reason)
            submission.waiters.forEach { $0.resume(returning: result) }
        }
    }

    private func pump() {
        guard !draining else { return }
        let next = pending.values
            .filter { $0.batch.previousCommittedBatchSequence == lastProcessedSequence }
            .min { $0.batch.batchSequence < $1.batch.batchSequence }
        guard let next else { return }
        pending.removeValue(forKey: next.batch.batchSequence)
        active = next
        draining = true
        drainTask = Task { [weak self] in
            let result = await next.process()
            guard let self else { return }
            await self.finished(sequence: next.batch.batchSequence, result: result)
        }
    }

    private func finished(
        sequence: UInt64,
        result: JourneyScreenEmissionDrainResult
    ) {
        guard let completed = active,
              completed.batch.batchSequence == sequence else { return }
        lastProcessedSequence = completed.batch.batchSequence
        processed[completed.batch.batchSequence] = (
            invocationId: completed.batch.invocationId,
            result: result
        )
        completed.waiters.forEach { $0.resume(returning: result) }

        let impossible = pending.values.filter { candidate in
            let previous = candidate.batch.previousCommittedBatchSequence
            return candidate.batch.batchSequence <= completed.batch.batchSequence
                || (previous != nil && previous! < completed.batch.batchSequence)
        }
        for candidate in impossible {
            pending.removeValue(forKey: candidate.batch.batchSequence)
            let rejected = candidate.reject()
            candidate.waiters.forEach { $0.resume(returning: rejected) }
        }

        active = nil
        draining = false
        drainTask = nil
        pump()
    }

    private func aborted(
        _ batch: ScreenEmissionBatch,
        reason: JourneyScreenEmissionSkipReason
    ) -> JourneyScreenEmissionDrainResult {
        JourneyScreenEmissionDrainResult(
            status: .aborted,
            acceptedEmissionIds: [],
            skippedEmissionIds: batch.emissions.map(\.id),
            reason: reason
        )
    }
}
#endif
