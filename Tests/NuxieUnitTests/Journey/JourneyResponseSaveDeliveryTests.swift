import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyResponseSaveDeliveryTests: XCTestCase {
    func testLatestSaveAttemptOwnsPersistedDisplayAcrossRestarts() async throws {
        struct Vector: Decodable {
            struct Step: Decodable {
                let action: String
                let sequence: Int64
                let code: String?
                let saving: Bool
                let saved: Bool
                let saveError: String
                let pending: [Int64]
            }
            let steps: [Step]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try ExactJSONCodec.decode(Vector.self,
            from: Data(contentsOf: root.appendingPathComponent("fixtures/responses/save-display.json")))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        var sheets: [Int64: JourneyResponseSave] = [:]
        var newest: Int64 = 0
        for step in vectors.steps {
            switch step.action {
            case "queue", "wait":
                let sheet = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: step.action == "queue")
                XCTAssertEqual(sheet.sequence, step.sequence)
                sheets[sheet.sequence] = sheet
                newest = sheet.sequence
            case "retry", "stop":
                _ = try await journal.recordResponseSaveReply(try XCTUnwrap(sheets[step.sequence]),
                    reply: .init(code: try XCTUnwrap(JourneyResponseSaveReply.Code(rawValue: step.code ?? "")), sequence: nil),
                    at: Date(timeIntervalSince1970: 1000))
            case "fail_wait":
                try await journal.recordWaitingResponseSaveReply(try XCTUnwrap(sheets[step.sequence]),
                    reply: .init(code: try XCTUnwrap(JourneyResponseSaveReply.Code(rawValue: step.code ?? "")), sequence: nil))
            case "confirm":
                try await journal.confirmResponseSave(try XCTUnwrap(sheets[step.sequence]), storedSequence: step.sequence)
            default: XCTFail("Unknown shared save-display action")
            }
            journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
            let states = try await journal.responseSaveDisplays(journeyId: run.journeyId)
            let state = try XCTUnwrap(states["feedback"])
            XCTAssertEqual(state.sequence, newest)
            XCTAssertEqual(state.saving, step.saving)
            XCTAssertEqual(state.saved, step.saved)
            XCTAssertEqual(state.saveError, step.saveError)
            let pending = try await journal.pendingResponseSaves()
            XCTAssertEqual(pending.map(\.sequence), step.pending)
        }
    }

    private struct Vectors: Decodable {
        struct Reply: Decodable {
            let bodyText: String
            let httpStatus: Int
            let expected: String
        }
        let request: ExactJSONObject<JourneyReleaseJSONValue>
        let replies: [Reply]
    }

    private func vectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ExactJSONCodec.decode(Vectors.self,
            from: Data(contentsOf: root.appendingPathComponent("fixtures/responses/save-cases.json")))
    }

    private func run(_ journal: JourneyRunJournal) async throws -> JourneyRun {
        let arm = ArmedJourney(reference: .init(experienceId: "experience-1", versionId: "version-1",
            legId: String(repeating: "a", count: 64), descriptorSha256: String(repeating: "b", count: 64)),
            binding: .init(type: .continuation, journeyId: "01900000-0000-7000-8000-000000000001", generation: 1),
            entryCondition: .init(type: .appForegrounded, eventName: nil, segmentId: nil, member: nil, condition: nil),
            context: .init(event: [:], responses: [:]))
        let admitted = try await journal.admit(arm: arm, release: testJourneyRelease(for: arm.reference),
            executionSnapshot: testJourneyExecutionSnapshot(), reentry: .init(type: .everyMatch, window: nil),
            entryStepId: "screen", at: Date(timeIntervalSince1970: 1000))
        return try XCTUnwrap(admitted)
    }

    private func api(host: String) -> NuxieApi {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return NuxieApi(apiKey: "test-key", baseURL: URL(string: "https://\(host)")!,
            urlSession: URLSession(configuration: configuration))
    }

    func testSharedWireAndReplyCasesIgnoreHTTPStatus() async throws {
        let suite = try vectors()
        let expectedSheet = try ExactJSONCodec.decode(JourneyResponseSave.self, from: ExactJSONCodec.encode(suite.request))
        for vector in suite.replies {
            for status in [vector.httpStatus, 201] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
                let run = try await run(journal)
                let sheet = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: expectedSheet.answers, queued: true)
                let host = UUID().uuidString.lowercased() + ".test"
                let expected = suite.request
                let responseData = Data(vector.bodyText.utf8)
                StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
                    XCTAssertEqual(request.url?.path, "/responses/save")
                    XCTAssertEqual(request.httpMethod, "POST")
                    let actual = try ExactJSONCodec.decode(ExactJSONObject<JourneyReleaseJSONValue>.self,
                        from: XCTUnwrap(request.httpBody))
                    XCTAssertEqual(actual, expected)
                    return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, responseData)
                }
                let reply = try await api(host: host).sendResponseSave(sheet)
                let stopped = try await journal.recordResponseSaveReply(sheet, reply: reply, at: Date(timeIntervalSince1970: 1000))
                let pending = try await journal.pendingResponseSaves()
                XCTAssertEqual(reply.confirmed, vector.expected == "confirmed")
                XCTAssertEqual(stopped, vector.expected == "stopped")
                XCTAssertEqual(pending.count, vector.expected.hasPrefix("retry") ? 1 : 0)
                if vector.expected.hasPrefix("retry") {
                    let attempts = try await journal.responseSaveAttempts(at: Date(timeIntervalSince1970: 1000))
                    XCTAssertEqual(attempts.first?.delay(at: Date(timeIntervalSince1970: 1000)), 5)
                    if vector.expected == "retry_until_deadline" {
                        XCTAssertEqual(reply.code, .unknownForm)
                        XCTAssertEqual(attempts.first?.unknownFormExpired(at: Date(timeIntervalSince1970: 1600)), true)
                    }
                }
            }
        }
    }

    func testWaitingFailureKeepsOlderSheetAndNewTapConfirmsWithoutQueueing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let older = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: ["stars": .number(1)], queued: true)
        _ = try await journal.recordResponseSaveReply(older, reply: .noAnswer, at: Date(timeIntervalSince1970: 1000))
        let host = UUID().uuidString.lowercased() + ".test"
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let sheet = try ExactJSONCodec.decode(JourneyResponseSave.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(sheet.distinctId, "anon")
            XCTAssertTrue([2, 3].contains(sheet.sequence))
            let body = sheet.sequence == 2 ? #"{"status":"error","code":"save_unavailable"}"# : #"{"status":"replayed","sequence":3}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host),
            clock: MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000)), sleeper: MockSleepProvider())
        addTeardownBlock { await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        let failed = try await delivery.sendWaiting(journal: journal, run: run, formName: "feedback", answers: [:])
        XCTAssertFalse(failed.confirmed)
        let pending = try await journal.pendingResponseSaves()
        XCTAssertEqual(pending, [older])
        let confirmed = try await delivery.sendWaiting(journal: journal, run: run, formName: "feedback", answers: [:])
        XCTAssertTrue(confirmed.confirmed)
        let final = try await journal.pendingResponseSaves()
        XCTAssertTrue(final.isEmpty)
        let next = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: false)
        XCTAssertEqual(next.sequence, 4)
    }

    func testAppBackgroundDoesNotDiscardAnAcceptedSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let started = expectation(description: "background request held")
        let transport = HeldResponseSaveTransport(started: started)
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport,
            clock: MockDateProvider(), sleeper: MockSleepProvider())
        let identity = MockIdentityService()
        identity.setDistinctId("anon")
        let events = MockEventLog()
        events.identity = identity
        let service = JourneyService(identity: identity, events: events, dateProvider: MockDateProvider(),
            sleepProvider: MockSleepProvider(), journalDirectory: directory, responseSaveDelivery: delivery,
            featureAccess: { _ in nil }, dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        addTeardownBlock { await transport.release(); await service.shutdown() }
        await delivery.activate(scope: .testFixture)
        _ = try await delivery.enqueue(journal: journal, run: run, formName: "feedback", answers: [:])
        await fulfillment(of: [started], timeout: 5)
        await service.onAppDidEnterBackground()
        await transport.release()
        for _ in 0..<100 {
            if try await journal.pendingResponseSaves().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = try await journal.pendingResponseSaves()
        XCTAssertTrue(pending.isEmpty)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.sequence), [1])
        await service.shutdown()
    }

    func testWaitingReplyAfterRunEndsDoesNotEraseNewerQueuedSheet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let started = expectation(description: "waiting request held")
        let transport = HeldResponseSaveTransport(started: started)
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport,
            clock: MockDateProvider(), sleeper: MockSleepProvider())
        addTeardownBlock { await transport.release(); await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        let waiting = Task { try await delivery.sendWaiting(journal: journal, run: run, formName: "feedback", answers: [:]) }
        await fulfillment(of: [started], timeout: 5)
        await delivery.shutdown()
        let replacement = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: ["stars": .number(2)], queued: true)
        try await journal.markStartedQueued(run)
        try await journal.complete(run.id, outcome: "done", at: Date())
        try await journal.markCompletionQueued(run)
        await transport.release()
        let reply = try await waiting.value
        XCTAssertTrue(reply.confirmed)
        let pending = try await journal.pendingResponseSaves()
        XCTAssertEqual(pending, [replacement])
        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.sequence), [1])
        await delivery.shutdown()
    }

    func testWaitingTransportPreservesEmptyAndLargeExactAnswerSheets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        var large: ExactJSONObject<JourneyReleaseJSONValue> = [:]
        for index in 0..<300 { large["field-\(index)"] = .string("invalid as typed") }
        large["é"] = .string("composed")
        large["e\u{301}"] = .string("decomposed")
        large["__proto__"] = .bool(false)
        for answers in [ExactJSONObject<JourneyReleaseJSONValue>(), large] {
            let host = UUID().uuidString.lowercased() + ".test"
            StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
                let sheet = try ExactJSONCodec.decode(JourneyResponseSave.self, from: XCTUnwrap(request.httpBody))
                XCTAssertEqual(sheet.answers, answers)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"status":"error","code":"invalid_request"}"#.utf8))
            }
            let delivery = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host),
                clock: MockDateProvider(), sleeper: MockSleepProvider())
            await delivery.activate(scope: .testFixture)
            let reply = try await delivery.sendWaiting(journal: journal, run: run, formName: "feedback", answers: answers)
            XCTAssertEqual(reply.code, .invalidRequest)
            await delivery.shutdown()
        }
    }

    func testUnknownFormDeadlineAndBackoffSurviveRestartAndBackwardClock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let sheet = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: true)
        let unknown = JourneyResponseSaveReply.decode(Data(#"{"status":"error","code":"unknown_form"}"#.utf8), attemptedSequence: 1)
        _ = try await journal.recordResponseSaveReply(sheet, reply: unknown, at: Date(timeIntervalSince1970: 1000))
        let reopened = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let backward = try await reopened.responseSaveAttempts(at: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(backward.first?.delay(at: Date(timeIntervalSince1970: 900)), 5)
        XCTAssertEqual(backward.first?.unknownFormExpired(at: Date(timeIntervalSince1970: 1499)), false)
        let restarted = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let before = try await restarted.responseSaveAttempts(at: Date(timeIntervalSince1970: 1499))
        XCTAssertEqual(before.first?.unknownFormExpired(at: Date(timeIntervalSince1970: 1499)), false)
        let atDeadline = try await restarted.responseSaveAttempts(at: Date(timeIntervalSince1970: 1500))
        XCTAssertEqual(atDeadline.first?.unknownFormExpired(at: Date(timeIntervalSince1970: 1500)), true)
        let stopped = try await restarted.recordResponseSaveReply(sheet, reply: unknown, at: Date(timeIntervalSince1970: 1500))
        XCTAssertTrue(stopped)
        let ended = try await restarted.pendingResponseSaves()
        XCTAssertTrue(ended.isEmpty)
        let next = try await restarted.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: true)
        for (time, delay) in [(2000.0, 5.0), (2005, 10), (2015, 20)] {
            let current = try JourneyRunJournal(directory: directory, distinctId: "anon")
            _ = try await current.recordResponseSaveReply(next, reply: .noAnswer, at: Date(timeIntervalSince1970: time))
            let attempts = try await current.responseSaveAttempts(at: Date(timeIntervalSince1970: time))
            XCTAssertEqual(attempts.first?.delay(at: Date(timeIntervalSince1970: time)), delay)
        }
    }

    func testWorkerRecoversNewestAnonymousSheetAfterOfflineCompletionAndSignIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sleeper = MockSleepProvider()
        let offline = expectation(description: "offline send")
        let host = UUID().uuidString.lowercased() + ".test"
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { _ in
            offline.fulfill()
            throw URLError(.notConnectedToInternet)
        }
        let first = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host), clock: clock, sleeper: sleeper)
        addTeardownBlock { await first.shutdown() }
        await first.activate(scope: .testFixture)
        _ = try await first.enqueue(journal: journal, run: run, formName: "feedback", answers: ["stars": .number(1)])
        await fulfillment(of: [offline], timeout: 5)
        await first.shutdown()
        _ = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: ["stars": .number(2)], queued: true)
        try await journal.markStartedQueued(run)
        try await journal.complete(run.id, outcome: "done", at: clock.now())
        try await journal.markCompletionQueued(run)
        let identity = MockIdentityService()
        identity.setDistinctId("signed-in")
        let currentJournal = try JourneyRunJournal(directory: directory, distinctId: identity.getDistinctId())
        let currentSheets = try await currentJournal.pendingResponseSaves()
        XCTAssertTrue(currentSheets.isEmpty)
        let online = expectation(description: "recovered send")
        let onlineHost = UUID().uuidString.lowercased() + ".test"
        let expected = Data(#"{"apiKey":"test-key","distinct_id":"anon","journey_id":"01900000-0000-7000-8000-000000000001","experience_id":"experience-1","experience_version_id":"version-1","form_name":"feedback","sequence":2,"answers":{"stars":2}}"#.utf8)
        StubURLProtocol.register(matcher: { $0.url?.host == onlineHost }) { request in
            XCTAssertEqual(try ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: XCTUnwrap(request.httpBody)),
                try ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: expected))
            online.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data(#"{"status":"saved","sequence":2}"#.utf8))
        }
        let second = JourneyResponseSaveDelivery(directory: directory, transport: api(host: onlineHost), clock: clock, sleeper: sleeper)
        addTeardownBlock { await second.shutdown() }
        await second.activate(scope: .testFixture)
        await fulfillment(of: [online], timeout: 5)
        for _ in 0..<100 {
            if try await journal.pendingResponseSaves().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let final = try await journal.pendingResponseSaves()
        XCTAssertTrue(final.isEmpty)
        await second.shutdown()
    }
    func testRecoverySkipsUnreadableJournalAndSendsValidOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: true)
        let damaged = directory.appendingPathComponent("journey-journal-v2/" + String(repeating: "c", count: 64) + ".json")
        try Data("unreadable journal".utf8).write(to: damaged)
        let recovery = try await JourneyRunJournal.recoverResponseSaveOwners(directory: directory, scope: .testFixture)
        XCTAssertEqual(recovery.owners, ["anon"])
        XCTAssertTrue(recovery.needsRetry)
        let sent = expectation(description: "valid owner's sheet")
        let host = UUID().uuidString.lowercased() + ".test"
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let sheet = try ExactJSONCodec.decode(JourneyResponseSave.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(sheet.distinctId, "anon")
            sent.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"status":"saved","sequence":1}"#.utf8))
        }
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host),
            clock: MockDateProvider(), sleeper: MockSleepProvider())
        addTeardownBlock { await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: damaged), Data("unreadable journal".utf8))
        await delivery.shutdown()
    }

    func testLongBackoffSleepsOnceAndEnqueueWakesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sheet = try await journal.reserveResponseSave(run: run, formName: "old", answers: [:], queued: true)
        for _ in 0..<7 { _ = try await journal.recordResponseSaveReply(sheet, reply: .noAnswer, at: clock.now()) }
        let sleeper = MockSleepProvider()
        let sent = expectation(description: "new sheet wakes long sleep")
        let host = UUID().uuidString.lowercased() + ".test"
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let body = try ExactJSONCodec.decode(JourneyResponseSave.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.formName, "new")
            sent.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"status":"saved","sequence":1}"#.utf8))
        }
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host), clock: clock, sleeper: sleeper)
        addTeardownBlock { await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        for _ in 0..<200 {
            if sleeper.pendingSleepCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(sleeper.sleepCalls.map(\.duration), [300])
        _ = try await delivery.enqueue(journal: journal, run: run, formName: "new", answers: [:])
        await fulfillment(of: [sent], timeout: 3)
        await delivery.shutdown()
    }

    func testUnreadableDiscoveryBacksOffWhileValidOwnerDelivers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "feedback", answers: [:], queued: true)
        let damaged = directory.appendingPathComponent("journey-journal-v2/" + String(repeating: "c", count: 64) + ".json")
        try Data("broken".utf8).write(to: damaged)
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sleeper = MockSleepProvider()
        let sent = expectation(description: "healthy sheet")
        let host = UUID().uuidString.lowercased() + ".test"
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            sent.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"status":"saved","sequence":1}"#.utf8))
        }
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: api(host: host), clock: clock, sleeper: sleeper)
        addTeardownBlock { await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        await fulfillment(of: [sent], timeout: 3)
        for (index, duration) in [5.0, 10, 20].enumerated() {
            for _ in 0..<200 {
                if sleeper.sleepCalls.count > index + (index > 0 ? 1 : 0) && sleeper.pendingSleepCount > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(sleeper.sleepCalls.last?.duration, duration)
            if index == 0 {
                clock.advance(by: -86_400)
                sleeper.completeAllSleeps()
                for _ in 0..<200 {
                    if sleeper.sleepCalls.count > 1 && sleeper.pendingSleepCount > 0 { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(sleeper.sleepCalls.last?.duration, 5, "Clock rollback preserves the remaining recovery delay")
            }
            clock.advance(by: duration)
            sleeper.completeAllSleeps()
        }
        await delivery.shutdown()
    }

    func testEnqueueDuringSendCannotReinstateReceiptBackoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("journey-journal-v2")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "first", answers: [:], queued: true)
        let started = expectation(description: "old send held")
        let transport = WakeDuringReceiptTransport(root: root, started: started)
        let sleeper = MockSleepProvider()
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport,
            clock: MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000)), sleeper: sleeper)
        addTeardownBlock { await transport.release(); await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        await fulfillment(of: [started], timeout: 3)
        _ = try await delivery.enqueue(journal: journal, run: run, formName: "new", answers: [:])
        await transport.release()
        for _ in 0..<200 {
            if try await journal.pendingResponseSaves().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = try await journal.pendingResponseSaves()
        XCTAssertTrue(pending.isEmpty, "A prior send cannot restore a backoff cleared by enqueue")
        XCTAssertTrue(sleeper.sleepCalls.isEmpty)
        await delivery.shutdown()
    }

    func testReceiptWriteFailureBacksOffAndRecovers() async throws {
        try await assertReceiptWriteRecovery(enqueueDuringBackoff: false)
    }

    func testEnqueueWakesReceiptWriteBackoff() async throws {
        try await assertReceiptWriteRecovery(enqueueDuringBackoff: true)
    }

    private func assertReceiptWriteRecovery(enqueueDuringBackoff: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("journey-journal-v2")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "first", answers: [:], queued: true)
        let clock = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1000))
        let sleeper = MockSleepProvider()
        let transport = ReceiptWriteFailureTransport(root: root)
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport, clock: clock, sleeper: sleeper)
        addTeardownBlock { await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        var observedSleeps = 0
        for (index, duration) in [5.0, 10, 20].enumerated() {
            for _ in 0..<200 {
                if sleeper.sleepCalls.count > observedSleeps && sleeper.pendingSleepCount > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(sleeper.sleepCalls.last?.duration, duration)
            observedSleeps += 1
            let count = await transport.count()
            XCTAssertEqual(count, index + 1, "One send precedes each receipt backoff")
            if index == 0 {
                clock.advance(by: -86_400)
                sleeper.completeAllSleeps()
                for _ in 0..<200 {
                    if sleeper.sleepCalls.count > observedSleeps && sleeper.pendingSleepCount > 0 { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(sleeper.sleepCalls.last?.duration, 5)
                let countAfterRollback = await transport.count()
                XCTAssertEqual(countAfterRollback, 1)
                observedSleeps += 1
            }
            if index < 2 { clock.advance(by: duration); sleeper.completeAllSleeps() }
        }
        try await transport.allowWrites()
        if enqueueDuringBackoff {
            _ = try await delivery.enqueue(journal: journal, run: run, formName: "new", answers: [:])
        } else {
            clock.advance(by: 20)
            sleeper.completeAllSleeps()
        }
        for _ in 0..<200 {
            if try await journal.pendingResponseSaves().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = try await journal.pendingResponseSaves()
        XCTAssertTrue(pending.isEmpty, "Receipt recovery confirms every sheet without advancing the clock for enqueue")
        let count = await transport.count()
        XCTAssertEqual(count, enqueueDuringBackoff ? 5 : 4)
        await delivery.shutdown()
    }

    func testReceiptWriteFailureNeverSendsAReplacedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("journey-journal-v2")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "first", answers: [:], queued: true)
        _ = try await journal.reserveResponseSave(run: run, formName: "second", answers: [:], queued: true)
        let started = expectation(description: "first request held")
        let transport = HeldResponseSaveTransport(started: started)
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport,
            clock: MockDateProvider(), sleeper: MockSleepProvider())
        addTeardownBlock { await transport.release(); await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        await fulfillment(of: [started], timeout: 5)
        let firstSheet = await transport.first()
        let first = try XCTUnwrap(firstSheet)
        let other = first.formName == "first" ? "second" : "first"
        _ = try await delivery.enqueue(journal: journal, run: run, formName: other, answers: ["new": .bool(true)])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await transport.release()
        try await Task.sleep(nanoseconds: 200_000_000)
        let requests = await transport.requests()
        XCTAssertFalse(requests.contains { $0.formName == other && $0.sequence == 1 })
        let retained = try await journal.pendingResponseSaves()
        XCTAssertEqual(retained.count, 2, "Receipt persistence must have failed")
        await delivery.shutdown()
    }

    func testWorkerReselectsUnsentSheetsAfterAnAwaitedSend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try JourneyRunJournal(directory: directory, distinctId: "anon")
        let run = try await run(journal)
        _ = try await journal.reserveResponseSave(run: run, formName: "first", answers: [:], queued: true)
        _ = try await journal.reserveResponseSave(run: run, formName: "second", answers: [:], queued: true)
        let started = expectation(description: "first request held")
        let transport = HeldResponseSaveTransport(started: started)
        let delivery = JourneyResponseSaveDelivery(directory: directory, transport: transport,
            clock: MockDateProvider(), sleeper: MockSleepProvider())
        addTeardownBlock { await transport.release(); await delivery.shutdown() }
        await delivery.activate(scope: .testFixture)
        await fulfillment(of: [started], timeout: 5)
        let firstSheet = await transport.first()
        let first = try XCTUnwrap(firstSheet)
        let other = first.formName == "first" ? "second" : "first"
        _ = try await delivery.enqueue(journal: journal, run: run, formName: other, answers: ["new": .bool(true)])
        await transport.release()
        for _ in 0..<100 {
            if try await journal.pendingResponseSaves().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.filter { $0.formName == other }.map(\.sequence), [2])
        await delivery.shutdown()
    }

}

private actor HeldResponseSaveTransport: JourneyResponseSaveTransport {
    private let started: XCTestExpectation
    private var sheets: [JourneyResponseSave] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(started: XCTestExpectation) { self.started = started }
    func first() -> JourneyResponseSave? { sheets.first }
    func requests() -> [JourneyResponseSave] { sheets }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply {
        sheets.append(sheet)
        if sheets.count == 1 {
            started.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
            return JourneyResponseSaveReply.decode(Data(#"{"status":"saved","sequence":1}"#.utf8), attemptedSequence: 1)
        }
        return JourneyResponseSaveReply.decode(Data(#"{"status":"saved","sequence":2}"#.utf8), attemptedSequence: 1)
    }
}

private actor ReceiptWriteFailureTransport: JourneyResponseSaveTransport {
    private let root: URL
    private var failing = true
    private var requests = 0
    init(root: URL) { self.root = root }
    func count() -> Int { requests }
    func allowWrites() throws {
        failing = false
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply {
        requests += 1
        if failing { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path) }
        return .init(code: .saved, sequence: sheet.sequence)
    }
}

private actor WakeDuringReceiptTransport: JourneyResponseSaveTransport {
    private let root: URL
    private let started: XCTestExpectation
    private var count = 0
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(root: URL, started: XCTestExpectation) { self.root = root; self.started = started }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply {
        count += 1
        if count == 1 {
            started.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        return .init(code: .saved, sequence: sheet.sequence)
    }
}
