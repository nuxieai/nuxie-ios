import Foundation

actor JourneyResponseSaveDelivery {
    private let directory: URL
    private let transport: any JourneyResponseSaveTransport
    private let clock: any DateProviderProtocol
    private let sleeper: any SleepProviderProtocol
    private var scope: JourneyStorageScope?
    private var journals: ExactJSONObject<JourneyRunJournal> = [:]
    private var receiptRetryAt: ExactJSONObject<Date> = [:]
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
        kick()
    }

    func enqueue(journal: JourneyRunJournal, run: JourneyRun, formName: String,
                 answers: ExactJSONObject<JourneyReleaseJSONValue>) async throws -> JourneyResponseSave {
        guard active, journal.responseSaveNamespace == scope?.conversionNamespace else {
            throw JourneyResponseSaveError.wrongOwner
        }
        let sheet = try await journal.reserveResponseSave(run: run, formName: formName, answers: answers, queued: true)
        journals[journal.distinctId] = journal
        workGeneration &+= 1
        kick()
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
        task?.cancel()
        await task?.value
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
                if !discovered {
                    let recovery = try await JourneyRunJournal.recoverResponseSaveOwners(directory: directory, scope: scope)
                    for owner in recovery.owners where journals[owner] == nil {
                        journals[owner] = try JourneyRunJournal(directory: directory, distinctId: owner, storageScope: scope)
                    }
                    discovered = !recovery.needsRetry
                }
                let observedGeneration = workGeneration
                var nextDelay: TimeInterval? = discovered ? nil : 5
                var sent = false
                deliveryPass: for journal in journals.values {
                    if let retryAt = receiptRetryAt[journal.distinctId] {
                        let remaining = min(5, retryAt.timeIntervalSince(clock.now()))
                        if remaining > 0 {
                            nextDelay = min(nextDelay ?? remaining, remaining)
                            continue
                        }
                        receiptRetryAt[journal.distinctId] = nil
                    }
                    let attempts: [JourneyResponseSaveAttempt]
                    do { attempts = try await journal.responseSaveAttempts(at: clock.now()) }
                    catch is CancellationError { return }
                    catch {
                        LogWarning("Response save journal could not be read")
                        nextDelay = min(nextDelay ?? 5, 5)
                        continue
                    }
                    for attempt in attempts {
                        try Task.checkCancellation()
                        let now = clock.now()
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
                        do { stopped = try await journal.recordResponseSaveReply(attempt.sheet, reply: reply, at: clock.now()) }
                        catch is CancellationError { return }
                        catch {
                            LogWarning("Response save receipt could not be persisted")
                            receiptRetryAt[journal.distinctId] = clock.now().addingTimeInterval(5)
                            sent = true
                            break deliveryPass
                        }
                        if stopped {
                            LogWarning("Response save stopped: code=\(reply.code.rawValue), journey=\(attempt.sheet.journeyId), form=\(attempt.sheet.formName), owner=\(attempt.sheet.distinctId)")
                        }
                        sent = true
                        break deliveryPass
                    }
                }
                if sent || observedGeneration != workGeneration { continue }
                guard let nextDelay else { return }
                try await sleeper.sleep(for: min(5, max(0.1, nextDelay)))
            } catch is CancellationError {
                return
            } catch {
                LogWarning("Response save delivery could not finish durable work")
                do { try await sleeper.sleep(for: 5) } catch { return }
            }
        }
    }
}
