#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime
@testable import NuxieTestSupport

final class JourneyNativeRunValuesTests: JourneyTestCase {
    func testNativeReadGateRetainsAnEarlyRelease() async {
        let gate = JourneyNthRoutedCaptureGate(eventName: "native", suspendedCall: 1)
        await gate.release()
        let finished = expectation(description: "An already released native read cannot park")
        let read = Task {
            await gate.intercept(event: "native")
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        // Unblock the red implementation after recording the failed oracle.
        await gate.release()
        await read.value
    }

    func testLiveFormAnswerObservationReadsWithoutSavingOrCreatingRunValues() async throws {
        try await verifyLiveFormAnswerObservation(retireNativeSession: false)
    }

    func testLiveFormAnswerObservationReturnsNilWhenNativeStateIsUnavailable() async throws {
        try await verifyLiveFormAnswerObservation(retireNativeSession: true)
    }

    func testLiveFormAnswerObservationThrowsForMalformedResponseSheet() async throws {
        try await verifyLiveFormAnswerObservation(retireNativeSession: false, mismatchedResponseModel: true)
    }

    private func verifyLiveFormAnswerObservation(retireNativeSession: Bool,
        mismatchedResponseModel: Bool = false) async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("rule-group-install")
        let policy = try JSONDecoder().decode(JourneyReleaseValuePolicy.self,
            from: Data(contentsOf: directory.appendingPathComponent("policy.json")))
        let storage = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(storage) }
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let presenter = await MainActor.run { RecordingJourneyPresenter() }
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(identity: identity, events: events, directory: storage, presenter: presenter)
        addTeardownBlock { await service.shutdown() }
        let absent = try await service.liveFormAnswersJSON(runID: "unknown", owner: "customer")
        XCTAssertNil(absent)
        let insertedUnknownRun = await service.hasNativeValuesForTesting(runID: "unknown")
        XCTAssertFalse(insertedUnknownRun, "An observation cannot create native run state")
        await service.initialize()
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let initial = try await authenticatedRenderedSnapshot(fixture)
        var responses = policy.responses
        if mismatchedResponseModel {
            let form = try XCTUnwrap(responses["profile"])
            responses["profile"] = .init(title: form.title, model: "DifferentResponseModel", fields: form.fields)
        }
        let snapshot = replacing(initial, responses: responses)
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let shown = await MainActor.run { presenter.request }
        let values = try XCTUnwrap(shown).runValues
        let journal = try JourneyRunJournal(directory: storage, distinctId: "customer")
        let runs = try await journal.runs()
        let runID = try XCTUnwrap(runs.first).id
        let file = try await NuxieNativePreparedFile.prepare(
            bytes: Data(contentsOf: directory.appendingPathComponent("screen.riv")), valuePolicy: policy.native)
        let prepared = try await values.native(in: file)
        let native = try XCTUnwrap(prepared)
        _ = try await native.sessions.mutate([
            .setString(instance: native.reference, path: "responses:profile/name", value: Data("Ada".utf8)),
        ])
        if mismatchedResponseModel {
            do {
                _ = try await service.liveFormAnswersJSON(runID: runID, owner: "customer")
                XCTFail("A malformed response sheet must throw instead of looking unavailable")
            } catch {
                XCTAssertEqual(error as? ExperienceInteractiveScreenError,
                    .stateContract("Native response form does not match its release"))
            }
            return
        }
        let before = try await values.snapshot()
        let observed = try await service.liveFormAnswersJSON(runID: runID, owner: "customer")
        let answers = try JSONDecoder().decode(ExactJSONObject<ExactJSONObject<JourneyReleaseJSONValue>>.self,
            from: XCTUnwrap(observed))
        XCTAssertEqual(answers["profile"]?["name"], .string("Ada"))
        let after = try await values.snapshot()
        XCTAssertEqual(before, after)
        let wrongOwner = try await service.liveFormAnswersJSON(runID: runID, owner: "other")
        XCTAssertNil(wrongOwner)
        let observedAgain = try await service.liveFormAnswersJSON(runID: runID, owner: "customer")
        let answersAgain = try JSONDecoder().decode(ExactJSONObject<ExactJSONObject<JourneyReleaseJSONValue>>.self,
            from: XCTUnwrap(observedAgain))
        XCTAssertEqual(answersAgain["profile"]?["name"], .string("Ada"))
        let journalAfter = try await journal.runs()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(journalAfter), try encoder.encode(runs))
        if retireNativeSession {
            try await native.sessions.retire()
            let unavailable = try await service.liveFormAnswersJSON(runID: runID, owner: "customer")
            XCTAssertNil(unavailable, "Unavailable native state has no live observation")
        }
        await service.shutdown()
        let retired = try await service.liveFormAnswersJSON(runID: runID, owner: "customer")
        XCTAssertNil(retired)
    }

    func testTimedWaitRestoresPublishedGoalsBeforeContinuingWithoutAScreen() async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let initial = try await authenticatedRenderedSnapshot(fixture)
        let steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
        [
          {"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
          {"kind":"action","id":"wait","action":{"type":"delay","durationMs":259200000},"outlets":{"next":"restored"}},
          {"kind":"action","id":"restored","action":{"type":"condition","branches":[{"id":"saved","condition":{"type":"Compare","op":"==","left":{"type":"Response.Field","key":"goals"},"right":{"type":"Array","items":[{"type":"Object","fields":{"title":{"type":"String","value":"Walk"}}},{"type":"Object","fields":{"title":{"type":"String","value":"Sleep"}}},{"type":"Object","fields":{"title":{"type":"String","value":"Read"}}}]}}}]},"outlets":{"saved":"done","default":"lost"}},
          {"kind":"complete","id":"done","outcome":"done"},
          {"kind":"complete","id":"lost","outcome":"lost"}
        ]
        """#.utf8))
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
        addTeardownBlock { await service.shutdown() }
        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        let shown = await MainActor.run { presenter.request }
        let request = try XCTUnwrap(shown)
        let goalsDirectory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let bytes = try Data(contentsOf: goalsDirectory.appendingPathComponent("screen.riv"))
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: bytes)
        let nativeResult = try await request.runValues.native(in: prepared)
        let native = try XCTUnwrap(nativeResult)
        let before = try await native.sessions.snapshot(native.reference)
        let list = try XCTUnwrap(before.values.first {
            $0.ownerInstanceID == before.rootInstanceID && $0.name == "goals"
        })
        guard case .list(let ids) = list.value, let firstID = ids.first else {
            return XCTFail("F5 must start with authored goal rows")
        }
        let schema = try XCTUnwrap(before.instances.first { $0.id == firstID }?.schemaIndex)
        let added = try await native.sessions.makeViewModel(schemaIndex: schema, authoredInstanceIndex: nil)
        _ = try await native.sessions.mutate([
            .setString(instance: added, path: "title", value: Data("Sleep".utf8)),
            .listMove(instance: native.reference, path: "goals", from: 1, to: 0),
            .listInsert(instance: native.reference, path: "goals", index: 1, value: added),
        ])
        let expected: JourneyReleaseJSONValue = .array([
            .object(["title": .string("Walk")]), .object(["title": .string("Sleep")]),
            .object(["title": .string("Read")]),
        ])
        let accepted = await request.onEmissionBatch(presentationBatch(request: request,
            invocationId: "goals-wait", emissions: [.init(id: UUID().uuidString, sequence: 0,
                occurredAt: "2026-08-29T12:00:00.120Z", name: "continue", payload: [:])]), nil)
        XCTAssertTrue(accepted)
        let journal = try JourneyRunJournal(directory: directory, distinctId: "customer")
        for _ in 0..<200 {
            if try await journal.runs().first?.park != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let waiting = try await journal.runs()
        let parked = try XCTUnwrap(waiting.first)
        XCTAssertEqual(parked.park?.wakeAt, clock.now().addingTimeInterval(259200))
        XCTAssertEqual(parked.nativeSnapshot?.journeyValues["goals"], expected)
        await service.onAppDidEnterBackground()
        await request.runValues.retire()
        clock.advance(by: 259200)
        let restartedEvents = MockEventLog()
        restartedEvents.identity = identity
        let noScreen = await MainActor.run { RecordingJourneyPresenter() }
        let restoredBeforeContinue = expectation(description: "Restore published list before continuing")
        let restarted = makeService(identity: identity, events: restartedEvents, directory: directory,
            dateProvider: clock, presenter: noScreen, prepareNativeValues: { values, pinned, _, _ in
                XCTAssertEqual(pinned.descriptorSHA256, release.descriptorSHA256)
                let file = try await NuxieNativePreparedFile.prepare(bytes: bytes)
                _ = try await values.native(in: file)
                let restored = try await values.journeyValues()
                XCTAssertEqual(restored["goals"], expected)
                XCTAssertFalse(restartedEvents.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
                restoredBeforeContinue.fulfill()
            }, readNativeValues: { try await $0.journeyValues() },
            pinnedReleaseAuthenticator: { _, _ in release })
        addTeardownBlock { await restarted.shutdown() }
        await restarted.initialize()
        await fulfillment(of: [restoredBeforeContinue], timeout: 3)
        let completed = restartedEvents.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.properties["outcome"] as? String, "done")
        let newScreen = await MainActor.run { noScreen.request }
        XCTAssertNil(newScreen)
    }

    func testThreeDayWaitRestoresNativeValuesBeforeAnyScreenPreparation() async throws {
        try await restartTimedWait(failFirstPreparation: false)
    }

    func testFailedPreparationKeepsTheWaitAndRetriesWithoutAnotherLaunch() async throws {
        try await restartTimedWait(failFirstPreparation: true)
    }

    func testEventSurvivesFailedRestorationAndRetriesBeforeTheWaitDeadline() async throws {
        try await restartTimedWait(failFirstPreparation: true, wakeEvent: true)
    }

    func testIdentityRoundTripDuringRestoreCannotConsumeCheckpoint() async throws {
        try await restartTimedWait(failFirstPreparation: false, revokeRead: true)
    }

    func testNestedTimedWaitRestoresBeforeTheConditionAndSendsDeepLeaf() async throws {
        try await restartTimedWait(failFirstPreparation: false, nested: true)
    }

    private func restartTimedWait(failFirstPreparation: Bool, wakeEvent: Bool = false, revokeRead: Bool = false, nested: Bool = false) async throws {
        let valueKey = nested ? "profile/minutes" : "trip_days"
        let written: Float = nested ? 20 : 30
        let sceneBytes = try nested
            ? Data(contentsOf: SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("nested-values/screen.riv"))
            : SharedValuesFixture.payload().sceneBytes
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
        if nested {
            steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
            [
              {"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
              {"kind":"action","id":"wait","action":{"type":"delay","durationMs":259200000},"outlets":{"next":"branch"}},
              {"kind":"action","id":"branch","action":{"type":"condition","branches":[{"id":"long","condition":{"type":"Compare","op":">","left":{"type":"Response.Field","key":"profile/minutes"},"right":{"type":"Number","value":15}}}]},"outlets":{"long":"emit","default":"short"}},
              {"kind":"action","id":"emit","action":{"type":"send_event","eventName":"nested_restored","payload":{"day":{"type":"Response.Field","key":"profile/settings/day"},"name":{"type":"Response.Field","key":"profile/name"}}},"outlets":{"next":"long"}},
              {"kind":"complete","id":"long","outcome":"long"},
              {"kind":"complete","id":"short","outcome":"short"}
            ]
            """#.utf8))
        }
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
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: sceneBytes)
        let nativeResult = try await request.runValues.native(in: prepared)
        let native = try XCTUnwrap(nativeResult)
        if nested {
            let before = try await request.runValues.journeyValues()
            XCTAssertEqual(before["profile/minutes"], .number(10))
            _ = try await native.sessions.mutate([.setString(instance: native.reference, path: "profile/settings/day", value: Data("2026-10-10".utf8))])
        }
        _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: valueKey, value: written)])
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
        XCTAssertEqual(run.nativeSnapshot?.journeyValues[valueKey], .number(Double(written)))
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
                let file = try await NuxieNativePreparedFile.prepare(bytes: sceneBytes)
                _ = try await values.native(in: file)
                let restored = try await values.journeyValues()
                XCTAssertEqual(restored[valueKey], .number(Double(written)))
            }, readNativeValues: { values in
                let result = try await values.journeyValues()
                if revokeRead {
                    identity.setDistinctId("other")
                    identity.setDistinctId("customer")
                }
                return result
            }, pinnedReleaseAuthenticator: { _, _ in release })
        await restarted.initialize()
        if revokeRead {
            let retained = try await journal.runs()
            XCTAssertNotNil(retained.first?.park)
            XCTAssertEqual(retained.first?.nativeSnapshot?.journeyValues[valueKey], .number(Double(written)))
            XCTAssertFalse(restartedEvents.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
            await restarted.shutdown()
            return
        }
        if wakeEvent {
            await restarted.handleEvent(NuxieEvent(name: "unlock", distinctId: "customer", properties: [:], timestamp: clock.now()))
        }
        if failFirstPreparation {
            let retained = try await journal.runs()
            XCTAssertNotNil(retained.first?.park)
            XCTAssertEqual(retained.first?.nativeSnapshot?.journeyValues[valueKey], .number(Double(written)))
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
        if nested {
            XCTAssertEqual(restartedEvents.routedEvents.first { $0.name == "nested_restored" }?.properties["day"] as? String, "2026-10-10")
            XCTAssertEqual(restartedEvents.routedEvents.first { $0.name == "nested_restored" }?.properties["name"] as? String, "Ana")
        }
        let newScreen = await MainActor.run { noScreen.request }
        XCTAssertNil(newScreen)
        await restarted.shutdown()
    }

    func testIdentityRoundTripDuringNativeCompletionReadCannotCompleteOldRun() async throws {
        try await identityRoundTripDuringNativeRead(park: false)
    }

    func testIdentityRoundTripDuringNativeReadCannotParkOldRun() async throws {
        try await identityRoundTripDuringNativeRead(park: true)
    }

    private func identityRoundTripDuringNativeRead(park: Bool) async throws {
        let fixture = try JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")
        let original = try await authenticatedRenderedSnapshot(fixture)
        let snapshot: JourneyProfileCatalog.Snapshot
        if park {
            let steps = try JSONDecoder().decode([Journey.Step].self, from: Data(#"""
            [{"kind":"action","id":"present","action":{"type":"navigate","screenId":"screen_welcome"},"outlets":{}},
             {"kind":"action","id":"wait","action":{"type":"delay","durationMs":259200000},"outlets":{"next":"done"}},
             {"kind":"complete","id":"done","outcome":"done"}]
            """#.utf8))
            let routes = try JSONDecoder().decode([Journey.Route].self, from: Data(#"[{"eventName":"$screen_dismissed","host":{"kind":"screen","screenId":"screen_welcome"},"entryStepId":"wait"}]"#.utf8))
            snapshot = replacing(original, entryStepId: "present", steps: steps, routes: routes)
        } else { snapshot = replacing(original, routes: []) }
        let gate = JourneyNthRoutedCaptureGate(eventName: "native", suspendedCall: 1)
        let entered = expectation(description: "Native read suspended")
        let context = try await makeRenderedJourneyTestContext(snapshot: snapshot, readNativeValues: { values in
            let result = try await values.journeyValues()
            if await gate.observationCount() == 0 { entered.fulfill() }
            await gate.intercept(event: "native")
            return result
        })
        defer { removeTemporaryDirectoryIfPresent(context.directory) }
        await context.service.profileDidCommit(snapshot, distinctId: "customer")
        let shown = await MainActor.run { context.presenter.request }
        let request = try XCTUnwrap(shown)
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
        _ = try await request.runValues.native(in: prepared)
        let finishing = Task {
            if park {
                _ = await request.onScreenDismissed("screen_welcome", nil, "user")
                return true
            }
            return await request.onOutcome(.dismissed, "screen_welcome")
        }
        await fulfillment(of: [entered], timeout: 3)
        for _ in 0..<100 {
            if await gate.isSuspended() { break }
            await Task.yield()
        }
        context.identity.setDistinctId("other")
        context.identity.setDistinctId("customer")
        await gate.release()
        let accepted = await finishing.value
        if !park { XCTAssertFalse(accepted) }
        XCTAssertFalse(context.events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted && (!park || $0.properties["outcome"] as? String != "abandoned") })
        let runs = try await context.journal.runs()
        if !park { XCTAssertNil(runs.first?.completion) }
        XCTAssertNil(runs.first?.park)
        await context.service.shutdown()
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
