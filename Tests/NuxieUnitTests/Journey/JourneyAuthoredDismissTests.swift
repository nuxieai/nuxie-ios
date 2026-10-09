#if canImport(UIKit)
import XCTest
@testable import Nuxie
@testable import NuxieRuntime
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyAuthoredDismissTests: JourneyTestCase {
    @MainActor
    func testPurchasedThenAuthoredDismissCompletesTheSameJourneyOnce() async throws {
        try await checkDismissal(commerce: "purchase")
    }

    @MainActor
    func testRestoredThenAuthoredDismissCompletesTheSameJourneyOnce() async throws {
        try await checkDismissal(commerce: "restore")
    }

    @MainActor
    func testGenuineUserCloseStillReportsHostDismissed() async throws {
        try await checkDismissal(commerce: nil)
    }

    @MainActor
    func testCancelledPurchaseWithoutOutletAllowsRetry() async throws {
        try await checkDismissal(commerce: "purchase", retryOutcome: SystemEventNames.purchaseCancelled)
    }

    @MainActor
    func testFailedPurchaseWithoutOutletAllowsRetry() async throws {
        try await checkDismissal(commerce: "purchase", retryOutcome: SystemEventNames.purchaseFailed)
    }

    @MainActor
    func testDeferredPurchaseAllowsAuthoredCloseThenCompletesOnce() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true)
    }

    @MainActor
    func testAuthoredCloseThenCancelledWithoutOutletKeepsCloseOutcome() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true, terminalOutcome: SystemEventNames.purchaseCancelled)
    }

    @MainActor
    func testAuthoredCloseThenFailedWithoutOutletKeepsCloseOutcome() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true, terminalOutcome: SystemEventNames.purchaseFailed)
    }

    @MainActor
    func testTerminalWaitsForAcceptedAuthoredRouteDuringHeldPublication() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true, holdClosePublication: true)
    }

    @MainActor
    func testDeclinedCommerceFrameKeepsSaveAndAwaitedConfirmation() async throws {
        try await checkDismissal(commerce: "purchase", saveInDeclinedFrame: true)
    }

    @MainActor
    func testFailedCompletionReadKeepsClosedPurchaseCorrelationForRetry() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true,
            terminalOutcome: SystemEventNames.purchaseFailed, failCompletionOnce: true)
    }

    @MainActor
    func testTerminalLookupStartedBeforeAuthoredCloseWaitsForThatRoute() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true,
            holdClosePublication: true, holdReleaseLookup: true)
    }

    @MainActor
    func testFailedTerminalLookupResumesAfterAuthoredCloseFinished() async throws {
        try await checkDismissal(commerce: "purchase", pendingClose: true,
            terminalOutcome: SystemEventNames.purchaseFailed, holdReleaseLookup: true)
    }

    @MainActor
    private func checkDismissal(commerce: String?, retryOutcome: String? = nil, pendingClose: Bool = false,
        terminalOutcome: String? = nil, holdClosePublication: Bool = false, saveInDeclinedFrame: Bool = false, failCompletionOnce: Bool = false, holdReleaseLookup: Bool = false) async throws {
        struct Corpus: Decodable {
            struct Vector: Decodable { let name, outcome: String; let reports: Int }
            let cases: [Vector]
        }
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/authored-dismiss.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixtureURL))
        let expected = try XCTUnwrap(corpus.cases.first { $0.name == (commerce ?? "user_close") })
        struct PendingCorpus: Decodable {
            struct Vector: Decodable { let terminalEvent, outcome: String; let reports, commerceOperations, authoredActions: Int }
            struct Save: Decodable {
                let accepted, confirmed: Bool
                let commerceOperations: Int
                let form: String
                let answers: [String: Double]
            }
            let cases: [Vector]
            let declinedFrameSave: Save
        }
        let pendingCorpus = try JSONDecoder().decode(PendingCorpus.self,
            from: Data(contentsOf: fixtureURL.deletingLastPathComponent().appendingPathComponent("pending-commerce.json")))
        let pendingExpected = try XCTUnwrap(pendingCorpus.cases.first {
            $0.terminalEvent == (terminalOutcome ?? SystemEventNames.purchaseCompleted)
        })
        let directory = temporaryDirectory()
        defer { removeTemporaryDirectoryIfPresent(directory) }
        let base = try await authenticatedRenderedSnapshot(JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry"))
        let type = commerce ?? "purchase"
        let action: [String: JourneyReleaseJSONValue] = type == "purchase"
            ? ["type": .string(type), "placementId": .string("golden:monthly")]
            : ["type": .string(type)]
        var snapshot = replacing(base, entryStepId: "present", steps: [
            .init(kind: .action, id: "present", action: ["type": .string("navigate"), "screenId": .string("screen_welcome")], outlets: [:], outcome: nil),
            .init(kind: .action, id: "commerce", action: action,
                outlets: [type == "purchase" ? "completed" : "restored": "dismiss"], outcome: nil),
            .init(kind: .action, id: "dismiss", action: ["type": .string("dismiss")], outlets: [:], outcome: nil),
            .init(kind: .action, id: "close_marker", action: ["type": .string("send_event"), "eventName": .string("authored_close_requested"), "payload": .object([:])], outlets: ["next": "close"], outcome: nil),
            .init(kind: .action, id: "close", action: ["type": .string("dismiss"), "reason": .string("author_closed")], outlets: [:], outcome: nil),
        ], routes: [
            .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: "buy", entryStepId: "commerce"),
            .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: "close", entryStepId: "close_marker")
        ])
        if type == "purchase" {
            let leg = try XCTUnwrap(snapshot.releasesByDigest.values.first).descriptor.leg
            snapshot = replacing(snapshot,
                offers: [.init(screenId: "screen_welcome", placementIds: ["golden:monthly"],
                    alreadyEntitledStepId: "skip", unknownStepId: "skip")],
                products: [releaseProductDocument(id: "monthly", storeProductId: "com.example.pro", featureIds: ["premium"])],
                steps: leg.steps + [.init(kind: .complete, id: "skip", action: nil, outlets: nil, outcome: "skipped")],
                routes: leg.routes + [
                    .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.alreadyEntitledEvent, entryStepId: "skip"),
                    .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.accessUnknownEvent, entryStepId: "skip"),
                ])
        }
        if saveInDeclinedFrame {
            snapshot = replacing(snapshot, responses: ["feedback": .init(title: "Feedback", model: "Responses:feedback", fields: [
                .init(key: "stars", label: "Stars", type: "number", values: nil, multiple: nil, rules: [])])])
        }
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let publicationGate = JourneyNthRoutedCaptureGate(eventName: "close", suspendedCall: 1)
        let releaseGate = JourneyNthRoutedCaptureGate(eventName: "release", suspendedCall: 1)
        let definition = try ExperienceDefinition(journeyDescriptor: release.descriptor)
        let experience = Experience(id: "test-experience", versionId: release.descriptor.identity.experienceVersionId,
            buildId: "test-build", artifactContentHash: nil, authenticatedReleaseID: nil,
            behaviorPresentation: .fullScreenDefault, behaviorPresentationScreens: ["screen_welcome": .init(width: 390, height: 844)],
            assetBaseURL: URL(string: "https://assets.example.com/")!,
            journey: .init(screens: definition.screens, viewModelValues: nil), definition: definition)
        let controller = AuthoredDismissCommerceController(mockExperienceVersionId: release.descriptor.identity.experienceVersionId,
            mockScreenId: "screen_welcome", mockExperience: experience)
        let experiences = MockExperienceService()
        experiences.defaultMockViewController = controller
        let windows = MockWindowProvider()
        let presentations = ExperiencePresentationService(windowProvider: windows, experiences: experiences,
            eventLog: events, identity: identity)
        let saveTransport = PendingCommerceSaveTransport()
        let saveDelivery = JourneyResponseSaveDelivery(directory: directory, transport: saveTransport,
            clock: SystemDateProvider(), sleeper: SystemSleepProvider())
        let completionFailure = PendingCommerceReadFailure()
        let formFile: NuxieNativePreparedFile? = saveInDeclinedFrame
            ? try await NuxieNativePreparedFile.prepare(bytes: Data(contentsOf: fixtureURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime/forms-saves/screen.riv"))) : nil
        let journeys = makeService(identity: identity, events: events, directory: directory,
            responseSaveDelivery: saveInDeclinedFrame ? saveDelivery : nil,
            featureAccess: { _ in .notFound }, presenter: presentations,
            readNativeValues: { values in
                try await completionFailure.read()
                if let formFile { _ = try await values.native(in: formFile) }
                return try await values.journeyValues()
            }, pinnedReleaseAuthenticator: { _, _ in
                if holdReleaseLookup { await releaseGate.intercept(event: "release") }
                return release
            })
        await journeys.initialize()
        await journeys.profileDidCommit(snapshot, distinctId: "customer")
        let journeyID = try XCTUnwrap(presentations.presentedJourneyId)
        XCTAssertTrue(presentations.isExperiencePresented)
        await controller.runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen_welcome")
        if let commerce {
            let batch = ScreenEmissionBatch(journeyId: journeyID, executionOwnershipEpoch: 0,
                lifecycleGeneration: 0, presentationEpoch: 1, batchSequence: 0,
                previousCommittedBatchSequence: nil, invocationId: "commerce-dismiss",
                source: .init(screenId: "screen_welcome", actionId: "buy", componentId: nil, instanceId: nil), emissions: [
                    .init(id: "00000000-0000-7000-8000-000000000901", sequence: 0,
                        occurredAt: "2026-08-29T12:00:00Z", name: "buy", payload: [:]),
                ])
            let accepted = await controller.runtimeDelegate?.experienceViewController(controller,
                didEmitScreenEmissionBatch: batch, frameSources: nil)
            XCTAssertEqual(accepted, true)
            for _ in 0..<200 where controller.correlation == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            var correlation = try XCTUnwrap(controller.correlation)
            if saveInDeclinedFrame {
                let confirmed = expectation(description: "Declined commerce frame save confirms")
                let sources = ExperienceEmissionSources(saves: [.init(
                    request: .init(form: "feedback", awaitTrigger: "saved", answers: ["stars": .number(4)]),
                    screenID: "screen_welcome", onConfirmed: { confirmed.fulfill() })])
                await controller.configureScreenEmissionRun(.init(journeyId: journeyID, screenId: "screen_welcome",
                    executionOwnershipEpoch: 0, lifecycleGeneration: 0, presentationEpoch: 1,
                    nextBatchSequence: 1, nextEmissionSequence: 1))
                let result = await controller.publishScreenInput(.effects(source: batch.source,
                    drafts: [.event(name: "buy", payload: [:])]), originatingRun: controller.captureScreenEmissionRun(),
                    eventSource: sources)
                XCTAssertEqual(result, .rejected)
                await fulfillment(of: [confirmed], timeout: 3)
                let requests = await saveTransport.requests
                let expectedSave = pendingCorpus.declinedFrameSave
                XCTAssertEqual(!requests.isEmpty, expectedSave.accepted)
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.formName, expectedSave.form)
                XCTAssertEqual(requests.first?.answers.count, expectedSave.answers.count)
                XCTAssertEqual(requests.first?.answers["stars"], .number(try XCTUnwrap(expectedSave.answers["stars"])))
                XCTAssertTrue(expectedSave.confirmed)
                XCTAssertEqual(controller.correlations.count, expectedSave.commerceOperations)
                XCTAssertTrue(presentations.isExperiencePresented)
                await journeys.shutdown()
                return
            }
            if let retryOutcome {
                let retryBatch = ScreenEmissionBatch(journeyId: journeyID, executionOwnershipEpoch: 0,
                    lifecycleGeneration: 0, presentationEpoch: 1, batchSequence: 1,
                    previousCommittedBatchSequence: 0, invocationId: "commerce-retry",
                    source: batch.source, emissions: [
                        .init(id: "00000000-0000-7000-8000-000000000902", sequence: 1,
                            occurredAt: "2026-08-29T12:00:01Z", name: "buy", payload: [:]),
                    ])
                func retry() async -> Bool? {
                    await controller.runtimeDelegate?.experienceViewController(controller,
                        didEmitScreenEmissionBatch: retryBatch, frameSources: nil)
                }
                let whilePending = await retry()
                XCTAssertEqual(whilePending, false, "An in-flight purchase rejects a second operation")
                await journeys.handleEvent(NuxieEvent(id: "unrelated-effect", name: retryOutcome,
                    distinctId: "customer", properties: ["placement_id": "golden:monthly"]))
                await journeys.handleEvent(NuxieEvent(id: correlation.eventId, name: retryOutcome,
                    distinctId: "other-customer", properties: ["placement_id": "golden:monthly"]))
                let afterUnrelated = await retry()
                XCTAssertEqual(afterUnrelated, false, "Only this owner's correlated outcome releases the operation")
                XCTAssertEqual(controller.correlations.count, 1)
                await journeys.handleEvent(NuxieEvent(id: correlation.eventId, name: retryOutcome,
                    distinctId: "customer", properties: ["placement_id": "golden:monthly"]))
                XCTAssertTrue(presentations.isExperiencePresented)
                XCTAssertEqual(presentations.presentedJourneyId, journeyID)
                XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
                let retried = await retry()
                XCTAssertEqual(retried, true, "A settled purchase without an outlet permits Subscribe again")
                for _ in 0..<200 where controller.correlations.count < 2 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertEqual(controller.correlations.count, 2)
                let previous = correlation
                correlation = try XCTUnwrap(controller.correlations.last)
                XCTAssertNotEqual(correlation.eventId, previous.eventId)
                await journeys.handleEvent(NuxieEvent(id: previous.eventId, name: SystemEventNames.purchaseCompleted,
                    distinctId: "customer", properties: ["placement_id": "golden:monthly"]))
                XCTAssertTrue(presentations.isExperiencePresented, "The first effect cannot complete the retry")
                XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
            }
            if pendingClose {
                await journeys.handleEvent(NuxieEvent(id: "pending-telemetry", name: SystemEventNames.purchasePending,
                    distinctId: "customer", properties: ["placement_id": "golden:monthly"]))
                let close = ScreenEmissionBatch(journeyId: journeyID, executionOwnershipEpoch: 0,
                    lifecycleGeneration: 0, presentationEpoch: 1, batchSequence: 1,
                    previousCommittedBatchSequence: 0, invocationId: "close-while-pending",
                    source: .init(screenId: "screen_welcome", actionId: "close", componentId: nil, instanceId: nil),
                    emissions: [.init(id: "00000000-0000-7000-8000-000000000903", sequence: 1,
                        occurredAt: "2026-08-29T12:00:02Z", name: "close", payload: [:])])
                if holdClosePublication {
                    events.beforeBatchCapture = { await publicationGate.intercept(event: "close") }
                }
                var earlyTerminal: Task<Bool, Never>?
                if holdReleaseLookup {
                    await journeys.profileDidCommit(removingDeliveredReleases(from: snapshot), distinctId: "customer")
                    let eventId = correlation.eventId
                    earlyTerminal = Task {
                        await journeys.handleEvent(NuxieEvent(id: eventId, name: terminalOutcome ?? SystemEventNames.purchaseCompleted,
                            distinctId: "customer", properties: ["placement_id": "golden:monthly"]),
                            admittedProfileGeneration: journeys.eventAdmissionGeneration())
                    }
                    for _ in 0..<200 {
                        if await releaseGate.isSuspended() { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let suspended = await releaseGate.isSuspended()
                    XCTAssertTrue(suspended)
                }
                let closeTask = Task { @MainActor in
                    await controller.runtimeDelegate?.experienceViewController(controller,
                        didEmitScreenEmissionBatch: close, frameSources: nil)
                }
                if holdClosePublication {
                    for _ in 0..<200 {
                        if await publicationGate.isSuspended() { break }
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    let suspended = await publicationGate.isSuspended()
                    XCTAssertTrue(suspended)
                    let accepted: Bool
                    if let earlyTerminal {
                        await releaseGate.release()
                        accepted = await earlyTerminal.value
                    } else {
                        accepted = await journeys.handleEvent(NuxieEvent(id: correlation.eventId,
                            name: SystemEventNames.purchaseCompleted, distinctId: "customer",
                            properties: ["placement_id": "golden:monthly"]),
                            admittedProfileGeneration: journeys.eventAdmissionGeneration())
                    }
                    XCTAssertFalse(accepted, "A terminal result stays pending until its accepted authored route finishes")
                    await publicationGate.release()
                }
                let closed = await closeTask.value
                XCTAssertEqual(closed, true, "An authored close is admitted while the purchase awaits its outcome")
                for _ in 0..<200 where presentations.isExperiencePresented { try await Task.sleep(nanoseconds: 10_000_000) }
                XCTAssertFalse(presentations.isExperiencePresented)
                XCTAssertEqual(events.routedEvents.filter { $0.name == "authored_close_requested" }.count, pendingExpected.authoredActions)
                if !holdClosePublication {
                    XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted },
                        "Closing the screen does not pretend the pending purchase completed")
                }
                XCTAssertEqual(controller.correlations.count, pendingExpected.commerceOperations)
                if !holdClosePublication {
                    let waiting = try await JourneyRunJournal(directory: directory, distinctId: "customer").runs()
                    XCTAssertEqual(waiting.count, 1)
                    XCTAssertEqual(waiting.first?.pendingCommerce?.effectId, correlation.eventId)
                    XCTAssertEqual(waiting.first?.pendingCommerce?.stepId, "commerce")
                    XCTAssertEqual(waiting.first?.authoredCloseOutcome, "author_closed")
                    for (id, owner) in [("unrelated", "customer"), (correlation.eventId, "another-customer")] {
                        await journeys.handleEvent(NuxieEvent(id: id, name: SystemEventNames.purchaseCompleted,
                            distinctId: owner, properties: ["placement_id": "golden:monthly"]))
                    }
                    XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
                }
                if holdReleaseLookup && !holdClosePublication, let earlyTerminal {
                    await releaseGate.release()
                    let accepted = await earlyTerminal.value
                    XCTAssertTrue(accepted)
                }
            }
            if failCompletionOnce {
                await completionFailure.arm()
                let settled = await journeys.handleEvent(NuxieEvent(id: correlation.eventId,
                    name: try XCTUnwrap(terminalOutcome), distinctId: "customer", properties: ["placement_id": "golden:monthly"]),
                    admittedProfileGeneration: journeys.eventAdmissionGeneration())
                XCTAssertFalse(settled)
                XCTAssertFalse(events.routedEvents.contains { $0.name == JourneyEvents.journeyCompleted })
            }
            await journeys.handleEvent(NuxieEvent(id: correlation.eventId,
                name: terminalOutcome ?? (commerce == "purchase" ? SystemEventNames.purchaseCompleted : SystemEventNames.restoreCompleted),
                distinctId: "customer", properties: commerce == "purchase" ? ["placement_id": "golden:monthly"] : [:]))
        } else {
            controller.performDismiss(reason: .userDismissed)
        }
        for _ in 0..<200 where presentations.isExperiencePresented || !events.routedEvents.contains(where: {
            $0.name == JourneyEvents.journeyCompleted
        }) { try await Task.sleep(nanoseconds: 10_000_000) }
        let completed = events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.count, pendingClose ? pendingExpected.reports : expected.reports)
        XCTAssertEqual(completed.first?.properties["journey_id"] as? String, journeyID)
        XCTAssertEqual(completed.first?.properties["outcome"] as? String, pendingClose ? pendingExpected.outcome : expected.outcome)
        XCTAssertFalse(presentations.isExperiencePresented)
        if pendingClose, let correlation = controller.correlation {
            await journeys.handleEvent(NuxieEvent(id: correlation.eventId, name: SystemEventNames.purchaseCompleted,
                distinctId: "customer", properties: ["placement_id": "golden:monthly"]))
            XCTAssertEqual(events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }.count, 1)
        }
        await journeys.shutdown()
    }
}

private actor PendingCommerceReadFailure {
    private var armed = false
    func arm() { armed = true }
    func read() throws {
        if armed { armed = false; throw CocoaError(.fileReadUnknown) }
    }
}

private actor PendingCommerceSaveTransport: JourneyResponseSaveTransport {
    private(set) var requests: [JourneyResponseSave] = []
    func sendResponseSave(_ sheet: JourneyResponseSave) async throws -> JourneyResponseSaveReply {
        requests.append(sheet)
        return .init(code: .saved, sequence: sheet.sequence)
    }
}

@MainActor
private final class AuthoredDismissCommerceController: MockExperienceViewController {
    private(set) var correlations: [CommerceOutcomeCorrelation] = []
    var correlation: CommerceOutcomeCorrelation? { correlations.last }

    private var preparedDismissal = false
    override func prepareForDismissal(reason: CloseReason? = nil) async {
        guard !preparedDismissal else { return }
        preparedDismissal = true
        await runtimeDelegate?.experienceViewController(self, didDismissScreen: "screen_welcome",
            revealingScreenId: nil, method: reason.map { ExperienceScreenDismissalMethod.value(for: $0) } ?? "experience")
    }

    override func performPurchase(placementId: String, outcomeCorrelation: CommerceOutcomeCorrelation?) {
        if let outcomeCorrelation { correlations.append(outcomeCorrelation) }
    }

    override func performRestore(outcomeCorrelation: CommerceOutcomeCorrelation?) {
        if let outcomeCorrelation { correlations.append(outcomeCorrelation) }
    }
}
#endif
