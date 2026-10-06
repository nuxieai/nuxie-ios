#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
@testable import NuxieTestSupport

final class JourneyNativeRunValuesTests: JourneyTestCase {
    func testThreeDayWaitRestoresNativeValuesBeforeAnyScreenPreparation() async throws {
        try await restartTimedWait(failFirstPreparation: false)
    }

    func testFailedPreparationKeepsTheWaitAndRetriesWithoutAnotherLaunch() async throws {
        try await restartTimedWait(failFirstPreparation: true)
    }

    func testEventSurvivesFailedRestorationAndRetriesBeforeTheWaitDeadline() async throws {
        try await restartTimedWait(failFirstPreparation: true, wakeEvent: true)
    }

    private func restartTimedWait(failFirstPreparation: Bool, wakeEvent: Bool = false) async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let initial = try await authenticatedRenderedSnapshot(fixture)
        var steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
        [
          {"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
          {"kind":"action","id":"wait","action":{"type":"delay","durationMs":259200000},"outlets":{"next":"branch"}},
          {"kind":"action","id":"branch","action":{"type":"condition","branches":[{"id":"long","condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"trip_days"},"right":{"type":"Number","value":30}}}]},"outlets":{"long":"long","default":"short"}},
          {"kind":"complete","id":"long","outcome":"long"},
          {"kind":"complete","id":"short","outcome":"short"}
        ]
        """#.utf8))
        if wakeEvent {
            steps[1] = try JSONDecoder().decode(Journey.Step.self, from: Data(#"""
            {"kind":"action","id":"wait","action":{"type":"wait_until","trigger":{"kind":"event","eventName":"unlock"},"condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"trip_days"},"right":{"type":"Number","value":30}},"maxTimeMs":259200000},"outlets":{"satisfied":"branch","timeout":"short"}}
            """#.utf8))
        }
        let routes = try JSONDecoder().decode([Journey.Route].self, from: Data(#"[{"eventName":"continue","host":{"kind":"screen","screenId":"screen_welcome"},"entryStepId":"wait"}]"#.utf8))
        let snapshot = replacing(initial, entryStepId: "present", steps: steps, routes: routes)
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let clock = MockDateProvider()
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let service = makeService(identity: identity, events: events, directory: directory,
            dateProvider: clock, presenter: presenter)
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let shown = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(shown)
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
        let nativeResult = try await request.runValues.native(in: prepared)
        let native = try XCTUnwrap(nativeResult)
        _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "trip_days", value: 30)])
        let accepted = await request.onEmissionBatch(presentationBatch(request: request,
            invocationId: "wait-continue", emissions: [.init(id: UUID().uuidString, sequence: 0,
                occurredAt: "2026-08-29T12:00:00.120Z", name: "continue", payload: [:])]), nil)
        XCTAssertTrue(accepted)
        let journal = try JourneyRunJournal(directory: directory, distinctId: "customer")
        for _ in 0..<200 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = try await journal.runs()
        let run = try XCTUnwrap(waiting.first)
        XCTAssertEqual(run.park?.wakeAt, clock.now().addingTimeInterval(259200))
        XCTAssertEqual(run.nativeSnapshot?.journeyValues["trip_days"], .number(30))
        XCTAssertTrue(run.context.responses.isEmpty)
        await service.onAppDidEnterBackground()
        await request.runValues.retire()
        clock.advance(by: wakeEvent ? 1 : 259200)
        let restartedEvents = MockEventLog()
        restartedEvents.identity = identity
        let noScreen = await MainActor.run { RecordingJourneyPresenter() }
        let attempts = NativePreparationAttempts(failFirst: failFirstPreparation)
        let sleeper = MockSleepProvider()
        let restarted = makeService(identity: identity, events: restartedEvents, directory: directory,
            dateProvider: clock, sleepProvider: sleeper, presenter: noScreen, prepareNativeValues: { values, pinned, _, _ in
                try await attempts.begin()
                XCTAssertEqual(pinned.descriptorSHA256, release.descriptorSHA256)
                let file = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
                _ = try await values.native(in: file)
                let restored = try await values.journeyValues()
                XCTAssertEqual(restored["trip_days"], .number(30))
            }, pinnedReleaseAuthenticator: { _, _ in release })
        await restarted.initialize()
        if wakeEvent {
            await restarted.handleEvent(NuxieEvent(name: "unlock", distinctId: "customer", properties: [:], timestamp: clock.now()))
        }
        if failFirstPreparation {
            let retained = try await journal.runs()
            XCTAssertNotNil(retained.first?.park)
            XCTAssertEqual(retained.first?.nativeSnapshot?.journeyValues["trip_days"], .number(30))
            XCTAssertFalse(restartedEvents.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
            for _ in 0..<100 where sleeper.pendingSleepCount == 0 { await Task.yield() }
            XCTAssertEqual(sleeper.pendingSleepDurations, [5])
            clock.advance(by: 5)
            sleeper.completeAllSleeps()
            for _ in 0..<200 {
                if restartedEvents.routedEvents.contains(where: { $0.name == JourneyEvents.journeyCompleted }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let completed = restartedEvents.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.properties["outcome"] as? String, "long")
        let newScreen = await MainActor.run { noScreen.request }
        XCTAssertNil(newScreen)
        await restarted.shutdown()
    }

    func testHostDismissedBoundaryReadsTheLiveNativeValue() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let snapshot = replacing(try await authenticatedRenderedSnapshot(fixture),
            completionOutputs: ["host_dismissed": .init(eventFields: [], responseFields: [
                ["key": .string("trip_days"), "type": .string("number"), "required": .bool(true)]
            ])], routes: [])
        let context = try await makeRenderedJourneyTestContext(snapshot: snapshot)
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        await context.service.profileDidCommit(snapshot, distinctId: "customer")
        let shown = await MainActor.run { context.presenter.request }
        let request = try XCTUnwrap(shown)
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
        let nativeResult = try await request.runValues.native(in: prepared)
        let native = try XCTUnwrap(nativeResult)
        _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "trip_days", value: 30)])
        let accepted = await request.onOutcome(.dismissed, "screen_welcome")
        XCTAssertTrue(accepted)
        let event = try XCTUnwrap(context.events.routedEvents.first { $0.name == JourneyEvents.journeyCompleted })
        XCTAssertEqual(event.properties["outcome"] as? String, "host_dismissed")
        let outputs = try XCTUnwrap(event.properties["outputs"] as? [String: Any])
        let values = try XCTUnwrap(outputs["responses"] as? [String: Any])
        XCTAssertEqual(values["trip_days"] as? Double, 30)
        await context.service.shutdown()
    }

    func testFrameRouteReadsTheNativeWriteWithoutAnAnswerEvent() async throws {
        for (days, outcome): (Float, String) in [(30, "long"), (7, "short")] {
            let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
            let initial = try await authenticatedRenderedSnapshot(fixture)
            let steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
            [
              {"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
              {"kind":"action","id":"branch","action":{"type":"condition","branches":[{"id":"long","condition":{"type":"Compare","op":">","left":{"type":"Response.Field","key":"trip_days"},"right":{"type":"Number","value":14}}}]},"outlets":{"long":"long","default":"short"}},
              {"kind":"complete","id":"long","outcome":"long"},
              {"kind":"complete","id":"short","outcome":"short"}
            ]
            """#.utf8))
            let routes = try JSONDecoder().decode([Journey.Route].self, from: Data(#"[{"eventName":"continue","host":{"kind":"screen","screenId":"screen_welcome"},"entryStepId":"branch"}]"#.utf8))
            let context = try await makeRenderedJourneyTestContext(snapshot: replacing(initial,
                entryStepId: "present", steps: steps, routes: routes))
            defer { removeTemporaryDirectoryIfPresent(context.directory) }
            await context.service.profileDidCommit(context.snapshot, distinctId: "customer")
            let shown = await MainActor.run { context.presenter.request }
            let request = try XCTUnwrap(shown)
            let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
            let nativeResult = try await request.runValues.native(in: prepared)
            let native = try XCTUnwrap(nativeResult)
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "trip_days", value: days)])
            XCTAssertEqual(context.events.routedEvents.map(\.name), [JourneyEvents.journeyStarted])
            let completed = expectation(description: "Native branch completed")
            context.events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in completed.fulfill() }
            let accepted = await request.onEmissionBatch(presentationBatch(request: request,
                invocationId: "native-continue", emissions: [
                    .init(id: UUID().uuidString, sequence: 0, occurredAt: "2026-08-29T12:00:00.120Z",
                        name: "$response_set", payload: ["field": .string("trip_days"), "value": .number(999)]),
                    .init(id: UUID().uuidString, sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.120Z", name: "continue", payload: [:])]), nil)
            XCTAssertTrue(accepted)
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertEqual(context.events.routedEvents.last?.properties["outcome"] as? String, outcome)
            XCTAssertEqual(context.events.routedEvents.map(\.name), [JourneyEvents.journeyStarted, "continue", JourneyEvents.journeyCompleted])
            await context.service.shutdown()
        }
    }
    func testBackgroundWaitPredicateReadsNativeValuesBeforeStagingTheEvent() async throws {
        for (days, outcome): (Float, String) in [(30, "long")] {
            let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
            let initial = try await authenticatedRenderedSnapshot(fixture)
            let steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
            [
              {"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
              {"kind":"action","id":"branch","action":{"type":"wait_until","trigger":{"kind":"event","eventName":"unlock"},"condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"trip_days"},"right":{"type":"Number","value":30}},"maxTimeMs":259200000},"outlets":{"satisfied":"long","timeout":"short"}},
              {"kind":"complete","id":"long","outcome":"long"},
              {"kind":"complete","id":"short","outcome":"short"}
            ]
            """#.utf8))
            let routes = try JSONDecoder().decode([Journey.Route].self, from: Data(#"[{"eventName":"continue","host":{"kind":"screen","screenId":"screen_welcome"},"entryStepId":"branch"}]"#.utf8))
            let context = try await makeRenderedJourneyTestContext(snapshot: replacing(initial,
                entryStepId: "present", steps: steps, routes: routes))
            defer { removeTemporaryDirectoryIfPresent(context.directory) }
            await context.service.profileDidCommit(context.snapshot, distinctId: "customer")
            let shown = await MainActor.run { context.presenter.request }
            let request = try XCTUnwrap(shown)
            let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
            let nativeResult = try await request.runValues.native(in: prepared)
            let native = try XCTUnwrap(nativeResult)
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "trip_days", value: days)])
            XCTAssertEqual(context.events.routedEvents.map(\.name), [JourneyEvents.journeyStarted])
            let completed = expectation(description: "Native branch completed")
            context.events.addEventHandler(pattern: JourneyEvents.journeyCompleted) { _ in completed.fulfill() }
            let accepted = await request.onEmissionBatch(presentationBatch(request: request,
                invocationId: "native-continue", emissions: [
                    .init(id: UUID().uuidString, sequence: 0, occurredAt: "2026-08-29T12:00:00.120Z",
                        name: "$response_set", payload: ["field": .string("trip_days"), "value": .number(999)]),
                    .init(id: UUID().uuidString, sequence: 1,
                    occurredAt: "2026-08-29T12:00:00.120Z", name: "continue", payload: [:])]), nil)
            XCTAssertTrue(accepted)
            let journal = try JourneyRunJournal(directory: context.directory, distinctId: "customer")
            for _ in 0..<200 {
                if try await journal.runs().first?.park != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await context.service.onAppDidEnterBackground()
            await context.service.handleEvent(NuxieEvent(name: "unlock", distinctId: "customer",
                properties: [:], timestamp: Date(timeIntervalSince1970: 1_000_000_001)))
            let parked = try await journal.runs()
            XCTAssertEqual(parked.first?.park?.pendingEvent?.name, "unlock")
            XCTAssertFalse(context.events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
            await context.service.onAppBecameActive()
            await fulfillment(of: [completed], timeout: 3)
            XCTAssertEqual(context.events.routedEvents.last?.properties["outcome"] as? String, outcome)
            XCTAssertEqual(context.events.routedEvents.map(\.name), [JourneyEvents.journeyStarted, "continue", JourneyEvents.journeyCompleted])
            await context.service.shutdown()
        }
    }
}
private actor NativePreparationAttempts {
    private var failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    func begin() throws {
        if failFirst {
            failFirst = false
            throw CocoaError(.fileReadUnknown)
        }
    }
}
#endif
