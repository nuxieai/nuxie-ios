import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLocalRuntimeStep1Tests: JourneyTestCase {
    private struct ApplyFixture: Decodable {
        struct Case: Decodable {
            struct Expected: Decodable { let enrollments: Int; let completionReports: Int; let logicalSteps: Int; let answer: Int }
            let name: String
            let crashPoint: String
            let triggerAtMillis: Int
            let inputAtMillis: Int
            let expected: Expected
        }
        let contract: String
        let cases: [Case]
    }
    private struct CompletionFixture: Decodable {
        struct Case: Decodable { let name: String; let privacyDrop: Bool; let cleanupFailure: Bool; let failurePoints: [String] }
        let contract: String
        let cases: [Case]
    }

    func testAppliedEventBeforeAcknowledgement() async throws {
        let fixture: ApplyFixture = try fixture("device-store-apply-crash")
        XCTAssertFalse(fixture.contract.isEmpty)
        for vector in fixture.cases {
            XCTAssertEqual(vector.crashPoint, "after_commit")
            let disk = try CustomerStoreTestDatabase()
            let snapshot = try await snapshot()
            let first = try await harness(disk: disk, snapshot: snapshot)
            first.clock.setCurrentDate(.init(timeIntervalSince1970: Double(vector.triggerAtMillis) / 1000))
            first.events.track("start", properties: ["answer": vector.expected.answer], userProperties: nil, userPropertiesSetOnce: nil)
            await first.events.drain()
            let before = try await first.store.activeJourneys(owner: first.owner)
            let reservedReportId = try XCTUnwrap(before.first?.completedEventId)
            let checkpoint = CustomerFixtureFault(target: .afterCommit)
            await first.store.setCustomerFaultInjector({ try checkpoint.visit($0) }, for: "completion")
            first.clock.setCurrentDate(.init(timeIntervalSince1970: Double(vector.inputAtMillis) / 1000))
            _ = await first.events.captureAndRouteSystemEvent(.init(name: "finish", properties: ["answer": vector.expected.answer], eventId: "finish", distinctId: "customer"))
            await waitForInput(first)
            await first.service.stopAfterInjectedCrash()
            await first.events.close()
            XCTAssertTrue(checkpoint.interrupted)
            let reportsBefore = try disk.strings("SELECT id FROM events WHERE event_role='completed';")
            XCTAssertEqual(reportsBefore, [reservedReportId], vector.name)
            let second = try await harness(disk: disk, snapshot: snapshot)
            second.clock.setCurrentDate(.init(timeIntervalSince1970: Double(vector.inputAtMillis) / 1000))
            _ = await second.events.captureAndRouteSystemEvent(.init(name: "finish", properties: ["answer": vector.expected.answer], eventId: "finish", distinctId: "customer"))
            await second.events.drain()
            let active = try await second.store.activeJourneys(owner: second.owner)
            XCTAssertTrue(active.isEmpty)
            XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE name='$journey_leg_started';"), Int64(vector.expected.enrollments))
            XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM events WHERE event_role='completed';"), Int64(vector.expected.completionReports))
            XCTAssertEqual(try disk.strings("SELECT id FROM events WHERE event_role='completed';"), reportsBefore)
            let report = try await second.store.queryEvent(id: reservedReportId)
            let properties = try XCTUnwrap(report).getPropertiesDict()
            let outputs = try XCTUnwrap(properties["outputs"] as? [String: Any])
            let eventOutputs = try XCTUnwrap(outputs["event"] as? [String: Any])
            XCTAssertEqual(eventOutputs["answer"] as? Int, vector.expected.answer)
            XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_frequency;"), Int64(vector.expected.logicalSteps))
            await second.service.stopAfterInjectedCrash()
            await second.events.close()
            try disk.remove()
        }
    }

    func testCompletionAndReportAreAtomic() async throws {
        let fixture: CompletionFixture = try fixture("device-store-leg-end-crash")
        XCTAssertFalse(fixture.contract.isEmpty)
        for vector in fixture.cases {
            let count = CustomerFixtureFault()
            let sampleDisk = try CustomerStoreTestDatabase()
            let snapshot = try await snapshot()
            let sample = try await harness(disk: sampleDisk, snapshot: snapshot, drop: vector.privacyDrop)
            sample.events.track("start", properties: ["answer": 42])
            await sample.events.drain()
            let sampleActive = try await sample.store.activeJourneys(owner: sample.owner)
            XCTAssertEqual(sampleActive.count, 1, vector.name)
            _ = try XCTUnwrap(sampleActive.first?.park, "The fixture must reach its wait before completion")
            await sample.store.setCustomerFaultInjector({ try count.visit($0) }, for: "completion")
            _ = await sample.events.captureAndRouteSystemEvent(.init(name: "finish", properties: ["answer": 42], eventId: "finish", distinctId: "customer"))
            await waitForInput(sample)
            await sample.service.stopAfterInjectedCrash()
            await sample.events.close()
            try sampleDisk.remove()
            let statementCount = try XCTUnwrap(count.statementCount > 0 ? count.statementCount : nil,
                "The fixture must exercise the completion transaction")
            var points: [CustomerTransactionFaultPoint] = []
            if vector.failurePoints.contains("each_statement") { points += (1...statementCount).map(CustomerTransactionFaultPoint.statement) }
            if vector.failurePoints.contains("before_commit") { points.append(.beforeCommit) }
            if vector.failurePoints.contains("after_commit") { points.append(.afterCommit) }
            for point in points {
                let disk = try CustomerStoreTestDatabase()
                let first = try await harness(disk: disk, snapshot: snapshot, drop: vector.privacyDrop)
                first.events.track("start", properties: ["answer": 42])
                await first.events.drain()
                let activeBefore = try await first.store.activeJourneys(owner: first.owner)
                let reportId = try XCTUnwrap(activeBefore.first?.completedEventId)
                let fault = CustomerFixtureFault(target: point)
                await first.store.setCustomerFaultInjector({ current in
                    if vector.cleanupFailure, current == .afterCommit {
                        let pins = disk.root.appendingPathComponent("journey-journal-v2/release-pins")
                        try FileManager.default.removeItem(at: pins)
                        try Data("cleanup-blocker".utf8).write(to: pins)
                    } else { try fault.visit(current) }
                }, for: "completion")
                _ = await first.events.captureAndRouteSystemEvent(.init(name: "finish", properties: ["answer": 42], eventId: "finish", distinctId: "customer"))
                await waitForInput(first)
                await first.service.stopAfterInjectedCrash()
                await first.events.close()
                let activeCount = try disk.integer("SELECT COUNT(*) FROM journeys;")
                let reportCount = try disk.integer("SELECT COUNT(*) FROM events WHERE id=\(CustomerStoreTestDatabase.quoted(reportId));")
                let dropCount = try disk.integer("SELECT COUNT(*) FROM stable_event_drops WHERE event_id=\(CustomerStoreTestDatabase.quoted(reportId));")
                if point == .afterCommit {
                    XCTAssertEqual(activeCount, 0, vector.name)
                    XCTAssertEqual(reportCount + dropCount, 1, vector.name)
                    XCTAssertEqual(dropCount, vector.privacyDrop ? 1 : 0)
                    XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_release_pins;"), 0)
                } else {
                    XCTAssertEqual(activeCount, 1, vector.name)
                    XCTAssertEqual(reportCount + dropCount, 0, vector.name)
                }
                let recovered = try await harness(disk: disk, snapshot: snapshot, drop: vector.privacyDrop)
                await recovered.events.drain()
                let remaining = try await recovered.store.activeJourneys(owner: recovered.owner)
                XCTAssertTrue(remaining.isEmpty)
                let settledReports = try disk.integer("SELECT COUNT(*) FROM events WHERE id=\(CustomerStoreTestDatabase.quoted(reportId));")
                let settledDrops = try disk.integer("SELECT COUNT(*) FROM stable_event_drops WHERE event_id=\(CustomerStoreTestDatabase.quoted(reportId));")
                XCTAssertEqual(settledReports + settledDrops, 1)
                XCTAssertEqual(try disk.integer("SELECT COUNT(*) FROM journey_frequency;"), 1)
                await recovered.service.stopAfterInjectedCrash()
                await recovered.events.close()
                try disk.remove()
            }
        }
    }

    private func fixture<T: Decodable>(_ name: String) throws -> T {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ExactJSONCodec.decode(T.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/sdk/\(name).json")))
    }

    private func waitForInput(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if harness.handled.isCompleted { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Fixture input did not reach its commit boundary within five seconds", file: file, line: line)
    }

    private func snapshot() async throws -> JourneyProfileCatalog.Snapshot {
        let fixture = try JourneyPlaneProfileTestFixture.load()
        let base = try await authenticatedSnapshot(fixture)
        let steps = try ExactJSONCodec.decode([Journey.Step].self, from: Data(#"[{"kind":"action","id":"wait","action":{"type":"wait_until","trigger":{"kind":"event","eventName":"finish"},"condition":{"type":"Truthy","value":{"type":"Boolean","value":true}},"maxTimeMs":60000},"outlets":{"satisfied":"done","timeout":"done"}},{"kind":"complete","id":"done","outcome":"done"}]"#.utf8))
        let headless = try replacingWithHeadlessArtifacts(replacing(base, entry: .init(type: .event, eventName: "start", segmentId: nil, member: nil, condition: nil),
            reentry: .init(type: .everyMatch, window: nil),
            inputs: .init(eventFields: [["key": .string("answer"), "type": .string("number"), "required": .bool(true)]], responseFields: []),
            completionOutputs: ["done": .init(eventFields: [["key": .string("answer"), "type": .string("number"), "required": .bool(true)]], responseFields: [])], entryStepId: "wait", steps: steps, screens: []))
        let release = try XCTUnwrap(headless.releasesByDigest.values.first)
        let original = try XCTUnwrap(base.profile.releases.first)
        let pin = JourneyReleaseProfileEntry(locator: original.locator,
            envelope: .init(mediaType: original.envelope.mediaType, encoding: original.envelope.encoding,
                descriptorSha256: release.descriptorSHA256, descriptorSizeBytes: release.exactDescriptorBytes.count,
                descriptorBytesBase64: release.exactDescriptorBytes.base64EncodedString(), signature: original.envelope.signature))
        let profile = headless.profile
        return .init(profile: .init(schemaVersion: profile.schemaVersion, status: profile.status, delivery: profile.delivery,
            features: profile.features, facts: profile.facts, armedLegs: profile.armedLegs, releases: [pin]),
            releasesByDigest: headless.releasesByDigest)
    }

    private struct Harness {
        let store: SQLiteEventStore
        let events: EventLog
        let service: JourneyService
        let clock: MockDateProvider
        let handled: JourneyCompletionFlag
        let owner = CustomerStoreOwner(scope: .testFixture, userId: "customer")
    }

    private func harness(disk: CustomerStoreTestDatabase, snapshot: JourneyProfileCatalog.Snapshot, drop: Bool = false) async throws -> Harness {
        let store = SQLiteEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let clock = MockDateProvider(initialDate: .init(timeIntervalSince1970: 100))
        let events = EventLog(identity: identity, dateProvider: clock, apiClient: MockNuxieApi(), store: store)
        let configuration = NuxieConfiguration(apiKey: "device-store-fixture")
        configuration.testingOverrides.customStoragePath = disk.root
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.testingOverrides.flushAt = 10000
        configuration.beforeSend = { event in
            if drop, event.name == JourneyEvents.journeyCompleted { return nil }
            guard event.name == "start" || event.name == "finish" else { return event }
            return NuxieEvent(id: event.id, name: event.name, forwardingName: event.forwardingName, distinctId: event.distinctId,
                properties: event.properties, timestamp: clock.now(), journeyOrigin: event.journeyOrigin)
        }
        let service = JourneyService(identity: identity, events: events, dateProvider: clock, sleepProvider: MockSleepProvider(),
            journalDirectory: disk.root, storageScope: .testFixture, featureAccess: { _ in nil },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events),
            pinnedReleaseAuthenticator: { pin, reference in
                guard let release = snapshot.releasesByDigest[reference.descriptorSha256],
                      pin.envelope.descriptorSha256 == reference.descriptorSha256,
                      Data(base64Encoded: pin.envelope.descriptorBytesBase64) == release.exactDescriptorBytes else { throw CustomerStoreError.invalidRow }
                return release
            }, timezones: try XCTUnwrap(SignedTimezoneBundle.installed))
        let handled = JourneyCompletionFlag()
        let reservation = events.reserveCommittedAdmission { service.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: reservation) { event, generation in
            let accepted = await service.handleEvent(event, admittedProfileGeneration: generation)
            if event.id == "finish" { handled.finish() }
            return accepted
        }
        await service.prepareForEvents()
        try await events.configure(configuration: configuration)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        return .init(store: store, events: events, service: service, clock: clock, handled: handled)
    }
}

private final class CustomerFixtureFault: @unchecked Sendable {
    private let lock = NSLock()
    private let target: CustomerTransactionFaultPoint?
    private var statements = 0
    private var didInterrupt = false
    init(target: CustomerTransactionFaultPoint? = nil) { self.target = target }
    var interrupted: Bool { lock.withLock { didInterrupt } }
    var statementCount: Int { lock.withLock { statements } }
    func visit(_ point: CustomerTransactionFaultPoint) throws {
        try lock.withLock {
            if case .statement(let number) = point { statements = max(statements, number) }
            if point == target { didInterrupt = true; throw CustomerExecutionTestFault.interrupted }
        }
    }
}
