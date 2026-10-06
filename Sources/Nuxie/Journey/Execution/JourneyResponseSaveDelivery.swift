import Foundation

actor JourneyResponseSaveDelivery {
    private let directory: URL
    private let transport: any JourneyResponseSaveTransport
    private let clock: any DateProviderProtocol
    private let sleeper: any SleepProviderProtocol
    private var scope: JourneyStorageScope?
    private var journals: ExactJSONObject<JourneyRunJournal> = [:]
    private var receiptBackoffs: ExactJSONObject<RetryBackoff> = [:]
    private struct RetryBackoff {
        var delay: TimeInterval = 5
        var retryAt: Date?
        mutating func failed(at now: Date) {
            retryAt = now.addingTimeInterval(delay)
            delay = min(300, delay * 2)
        }
    }
    private var discoveryBackoff = RetryBackoff()
    private var readBackoffs: ExactJSONObject<RetryBackoff> = [:]
    private var sleeping: Task<Void, Error>?
    private var lastClockReading: Date?
    private var discovered = false
    private var workGeneration: UInt64 = 0
    private var active = false
    private var worker: (id: UUID, task: Task<Void, Never>)?

    init(directory: URL, transport: any JourneyResponseSaveTransport,
         clock: any DateProviderProtocol, sleeper: any SleepProviderProtocol) {
        self.directory = directory
        self.transport = transport
        self.clock = clock
        self.sleeper = sleeper
    }

    func activate(scope: JourneyStorageScope) {
        guard self.scope == nil || self.scope == scope else { return }
        self.scope = scope
        active = true
        wake()
    }

    func enqueue(journal: JourneyRunJournal, run: JourneyRun, formName: String,
                 answers: ExactJSONObject<JourneyReleaseJSONValue>) async throws -> JourneyResponseSave {
        guard active, journal.responseSaveNamespace == scope?.conversionNamespace else {
            throw JourneyResponseSaveError.wrongOwner
        }
        let sheet = try await journal.reserveResponseSave(run: run, formName: formName, answers: answers, queued: true)
        journals[journal.distinctId] = journal
        wake()
        return sheet
    }

    func sendWaiting(journal: JourneyRunJournal, run: JourneyRun, formName: String,
                     answers: ExactJSONObject<JourneyReleaseJSONValue>) async throws -> JourneyResponseSaveReply {
        guard active, journal.responseSaveNamespace == scope?.conversionNamespace else {
            throw JourneyResponseSaveError.wrongOwner
        }
        let sheet = try await journal.reserveResponseSave(run: run, formName: formName, answers: answers, queued: false)
        try Task.checkCancellation()
        guard active else { throw CancellationError() }
        let reply: JourneyResponseSaveReply
        do { reply = try await transport.sendResponseSave(sheet) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return .noAnswer }
        try Task.checkCancellation()
        if reply.confirmed, let sequence = reply.sequence {
            try await journal.confirmResponseSave(sheet, storedSequence: sequence)
        }
        return reply
    }

    func shutdown() async {
        active = false
        let task = worker?.task
        worker = nil
        sleeping?.cancel()
        task?.cancel()
        await task?.value
    }

    private func currentTime() -> Date {
        let now = clock.now()
        if let previous = lastClockReading, now < previous {
            let shift = now.timeIntervalSince(previous)
            discoveryBackoff.retryAt = discoveryBackoff.retryAt?.addingTimeInterval(shift)
            for owner in readBackoffs.keys {
                if var backoff = readBackoffs[owner] {
                    backoff.retryAt = backoff.retryAt?.addingTimeInterval(shift)
                    readBackoffs[owner] = backoff
                }
            }
            for owner in receiptBackoffs.keys {
                if var backoff = receiptBackoffs[owner] {
                    backoff.retryAt = backoff.retryAt?.addingTimeInterval(shift)
                    receiptBackoffs[owner] = backoff
                }
            }
        }
        lastClockReading = now
        return now
    }

    private func wake() {
        workGeneration &+= 1
        discoveryBackoff = RetryBackoff()
        readBackoffs = [:]
        receiptBackoffs = [:]
        sleeping?.cancel()
        kick()
    }

    private func pause(for delay: TimeInterval, generation: UInt64) async throws {
        guard generation == workGeneration else { return }
        let task = Task { try await sleeper.sleep(for: max(0.1, delay)) }
        sleeping = task
        defer { sleeping = nil }
        do { try await task.value }
        catch is CancellationError { try Task.checkCancellation() }
    }

    private func kick() {
        guard active, worker == nil else { return }
        let id = UUID()
        worker = (id, Task { await self.deliver(id: id) })
    }

    private func deliver(id: UUID) async {
        defer { if worker?.id == id { worker = nil } }
        while active && !Task.isCancelled {
            do {
                guard let scope else { return }
                let observedGeneration = workGeneration
                let now = currentTime()
                if !discovered && (discoveryBackoff.retryAt ?? .distantPast) <= now {
                    do {
                        let recovery = try await JourneyRunJournal.recoverResponseSaveOwners(directory: directory, scope: scope)
                        for owner in recovery.owners where journals[owner] == nil {
                            journals[owner] = try JourneyRunJournal(directory: directory, distinctId: owner, storageScope: scope)
                        }
                        discovered = !recovery.needsRetry
                        if recovery.needsRetry { discoveryBackoff.failed(at: currentTime()) }
                    } catch is CancellationError { return }
                    catch {
                        LogWarning("Response save journals could not be discovered")
                        discoveryBackoff.failed(at: currentTime())
                    }
                }
                var nextDelay: TimeInterval? = discovered ? nil : discoveryBackoff.retryAt?.timeIntervalSince(currentTime())
                var sent = false
                deliveryPass: for journal in journals.values {
                    let now = currentTime()
                    if let retryAt = readBackoffs[journal.distinctId]?.retryAt, retryAt > now {
                        let remaining = retryAt.timeIntervalSince(currentTime())
                        nextDelay = min(nextDelay ?? remaining, remaining)
                        continue
                    }
                    if let retryAt = receiptBackoffs[journal.distinctId]?.retryAt {
                        let remaining = retryAt.timeIntervalSince(currentTime())
                        if remaining > 0 {
                            nextDelay = min(nextDelay ?? remaining, remaining)
                            continue
                        }
                    }
                    let attempts: [JourneyResponseSaveAttempt]
                    do { attempts = try await journal.responseSaveAttempts(at: currentTime()) }
                    catch is CancellationError { return }
                    catch {
                        LogWarning("Response save journal could not be read")
                        var backoff = readBackoffs[journal.distinctId] ?? RetryBackoff()
                        backoff.failed(at: currentTime())
                        readBackoffs[journal.distinctId] = backoff
                        let remaining = backoff.retryAt!.timeIntervalSince(currentTime())
                        nextDelay = min(nextDelay ?? remaining, remaining)
                        continue
                    }
                    readBackoffs[journal.distinctId] = nil
                    if attempts.isEmpty && observedGeneration == workGeneration {
                        journals[journal.distinctId] = nil
                    }
                    for attempt in attempts {
                        try Task.checkCancellation()
                        let now = currentTime()
                        let reply: JourneyResponseSaveReply
                        if attempt.unknownFormExpired(at: now) {
                            reply = .init(code: .unknownForm, sequence: nil)
                        } else if attempt.delay(at: now) > 0 {
                            nextDelay = min(nextDelay ?? .infinity, attempt.delay(at: now))
                            continue
                        } else {
                            do { reply = try await transport.sendResponseSave(attempt.sheet) }
                            catch is CancellationError { throw CancellationError() }
                            catch { try Task.checkCancellation(); reply = .noAnswer }
                        }
                        try Task.checkCancellation()
                        let stopped: Bool
                        do { stopped = try await journal.recordResponseSaveReply(attempt.sheet, reply: reply, at: currentTime()) }
                        catch is CancellationError { return }
                        catch {
                            LogWarning("Response save receipt could not be persisted")
                            var backoff = receiptBackoffs[journal.distinctId] ?? RetryBackoff()
                            backoff.failed(at: currentTime())
                            receiptBackoffs[journal.distinctId] = backoff
                            sent = true
                            break deliveryPass
                        }
                        receiptBackoffs[journal.distinctId] = nil
                        if stopped {
                            LogWarning("Response save stopped: code=\(reply.code.rawValue), journey=\(attempt.sheet.journeyId), form=\(attempt.sheet.formName), owner=\(attempt.sheet.distinctId)")
                        }
                        sent = true
                        break deliveryPass
                    }
                }
                if sent || observedGeneration != workGeneration { continue }
                guard let nextDelay else { return }
                try await pause(for: nextDelay, generation: observedGeneration)
            } catch is CancellationError {
                return
            } catch {
                LogWarning("Response save delivery could not finish durable work")
                discoveryBackoff.failed(at: currentTime())
                do { try await pause(for: discoveryBackoff.retryAt!.timeIntervalSince(currentTime()), generation: workGeneration) }
                catch { return }
            }
        }
    }
}
