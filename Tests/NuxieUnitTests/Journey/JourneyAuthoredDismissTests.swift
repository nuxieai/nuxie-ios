#if canImport(UIKit)
import XCTest
@testable import Nuxie
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
    private func checkDismissal(commerce: String?, retryOutcome: String? = nil) async throws {
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
        ], routes: [.init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: "buy", entryStepId: "commerce")])
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
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let controller = AuthoredDismissCommerceController(mockExperienceVersionId: release.descriptor.identity.experienceVersionId,
            mockScreenId: "screen_welcome")
        let experiences = MockExperienceService()
        experiences.defaultMockViewController = controller
        let windows = MockWindowProvider()
        let presentations = ExperiencePresentationService(windowProvider: windows, experiences: experiences,
            eventLog: events, identity: identity)
        let journeys = makeService(identity: identity, events: events, directory: directory,
            featureAccess: { _ in .notFound }, presenter: presentations)
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
            await journeys.handleEvent(NuxieEvent(id: correlation.eventId,
                name: commerce == "purchase" ? SystemEventNames.purchaseCompleted : SystemEventNames.restoreCompleted,
                distinctId: "customer", properties: commerce == "purchase" ? ["placement_id": "golden:monthly"] : [:]))
        } else {
            controller.performDismiss(reason: .userDismissed)
        }
        for _ in 0..<200 where presentations.isExperiencePresented || !events.routedEvents.contains(where: {
            $0.name == JourneyEvents.journeyCompleted
        }) { try await Task.sleep(nanoseconds: 10_000_000) }
        let completed = events.routedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.count, expected.reports)
        XCTAssertEqual(completed.first?.properties["journey_id"] as? String, journeyID)
        XCTAssertEqual(completed.first?.properties["outcome"] as? String, expected.outcome)
        XCTAssertFalse(presentations.isExperiencePresented)
        await journeys.shutdown()
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
